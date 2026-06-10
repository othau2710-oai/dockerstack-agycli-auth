"use strict";

/**
 * dockerService.js
 * All Docker-related operations for the agy login flow.
 * Logic ported from wrapper.js — keep behaviour identical.
 *
 * NOTE on multi-session strategy:
 *   The credential file path inside the container is fixed
 *   (/root/.gemini/antigravity-cli/antigravity-oauth-token).
 *   Concurrent sessions share that file → conflicts.
 *
 *   Option A (default, used here): a global mutex enforces 1 active session.
 *     Subsequent sessions wait in queue.
 *
 *   Option B (commented below): per-session HOME via
 *     `-e HOME=/tmp/agy-session-${sessionId}` makes the credential path
 *     `/tmp/agy-session-${sessionId}/.gemini/antigravity-cli/...`. Switch by
 *     replacing CONFIG.credentialPath usage with a per-session path and
 *     adding the HOME env var to spawnAgySession + waitForCredential +
 *     readCredentialFile + resetCredential.
 */

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { once } = require("events");
const { spawn, execFile } = require("child_process");
const { finished } = require("stream/promises");

const CONFIG = {
  containerName: process.env.CONTAINER_NAME || "agy-dev",
  credentialPath: process.env.AGY_CREDENTIAL_PATH || "/root/.gemini/antigravity-cli/antigravity-oauth-token",
  authProbePrompt: process.env.AGY_LOGIN_PROMPT || "__antigravity_auth_check__",
  // ⬆️ Default nâng 1s → 5s: trên Azure cold-start agent, 1s quá gắt khiến agy
  //    chưa kịp in OAuth URL trong print-mode. Vẫn override được qua env.
  authProbeTimeout: process.env.AGY_LOGIN_PRINT_TIMEOUT || "5s",
  // ⏱️ Thời gian backend chờ OAuth URL xuất hiện trên stdout/stderr (ms).
  //    Trước đây hardcode 30s trong login.js, không cấu hình được → trên môi
  //    trường chậm (Azure) thường timeout trước khi URL kịp in. Mặc định 60s.
  urlWaitTimeoutMs: parseInt(process.env.AGY_URL_WAIT_TIMEOUT_MS || "60000", 10),
  credentialCheckTimeoutMs: parseInt(process.env.AGY_CREDENTIAL_CHECK_TIMEOUT || "20000", 10),
  credentialCheckIntervalMs: parseInt(process.env.AGY_CREDENTIAL_CHECK_INTERVAL || "500", 10),
  codeWriteTimeoutMs: 15_000,
  snapshotRoots: parseEnvList(process.env.AGY_SNAPSHOT_ROOTS || "/root"),
  snapshotOutputDir: process.env.AGY_SNAPSHOT_OUTPUT_DIR || path.resolve(process.cwd(), "login-snapshot"),
  snapshotTimeoutMs: parseInt(process.env.AGY_SNAPSHOT_TIMEOUT_MS || "30000", 10),
  snapshotCopyLimit: parseInt(process.env.AGY_SNAPSHOT_COPY_LIMIT || "80", 10),
  snapshotMaxFileBytes: parseInt(process.env.AGY_SNAPSHOT_MAX_FILE_BYTES || "52428800", 10),
};

const log = {
  info: (msg) => console.log(`ℹ  [DOCKER] ${msg}`),
  warn: (msg) => console.warn(`⚠  [DOCKER] ${msg}`),
  err: (msg) => console.error(`✗  [DOCKER] ${msg}`),
  ok: (msg) => console.log(`✓  [DOCKER] ${msg}`),
  step: (msg) => console.log(`→  [DOCKER] ${msg}`),
};

// ─── Global mutex (Option A) ──────────────────────────────────────────────────

let activeSessionId = null;
const queue = [];

function acquireMutex(sessionId) {
  if (!activeSessionId) {
    activeSessionId = sessionId;
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    queue.push({ sessionId, resolve });
  });
}

function releaseMutex(sessionId) {
  if (activeSessionId !== sessionId) return;
  activeSessionId = null;
  const next = queue.shift();
  if (next) {
    activeSessionId = next.sessionId;
    next.resolve();
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function parseEnvList(value) {
  return String(value || "")
    .split(/[,\r\n]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

/**
 * Distinguish "docker CLI not installed" vs "daemon down" vs "container missing"
 * so error messages are actionable.
 */
function classifyDockerError(err) {
  const msg = (err && err.message) || "";
  const stderr = (err && err.stderr) || "";
  const combined = `${msg} ${stderr}`;
  if (msg.includes("ENOENT") || msg.includes("spawn docker")) {
    return {
      code: "DOCKER_CLI_MISSING",
      hint: "Docker CLI is not installed in the backend host. Install Docker or run the backend inside docker-compose with /var/run/docker.sock mounted.",
    };
  }
  if (
    combined.includes("Cannot connect to the Docker daemon") ||
    combined.includes("docker.sock") ||
    combined.includes("connect: no such file or directory")
  ) {
    return {
      code: "DOCKER_DAEMON_DOWN",
      hint: "Docker daemon is not running or socket is not accessible. Start Docker Desktop / dockerd, or mount /var/run/docker.sock into this container.",
    };
  }
  if (combined.includes("No such container")) {
    return { code: "CONTAINER_MISSING", hint: `Container does not exist yet. Run 'docker compose up -d' to build and start it.` };
  }
  return { code: "DOCKER_UNKNOWN", hint: msg };
}

let cachedDockerEnv = null; // { available, daemonOk, error, checkedAt }

/**
 * Quick environment probe: runs `docker version --format '{{.Server.Version}}'`.
 * Returns a structured status object. Cached for 5s to avoid hot-loop checks.
 */
async function checkDockerEnv({ force = false } = {}) {
  const now = Date.now();
  if (!force && cachedDockerEnv && now - cachedDockerEnv.checkedAt < 5000) {
    return cachedDockerEnv;
  }
  let result = { available: false, daemonOk: false, error: null, checkedAt: now };
  try {
    await execDocker(["version", "--format", "{{.Server.Version}}"], { timeoutMs: 5000 });
    result = { available: true, daemonOk: true, error: null, checkedAt: now };
  } catch (err) {
    const cls = classifyDockerError(err);
    result = {
      available: cls.code !== "DOCKER_CLI_MISSING",
      daemonOk: false,
      error: { code: cls.code, hint: cls.hint, raw: (err && err.message) || String(err) },
      checkedAt: now,
    };
  }
  cachedDockerEnv = result;
  return result;
}

function execDocker(args, { timeoutMs = 15000 } = {}) {
  return new Promise((resolve, reject) => {
    execFile("docker", args, { timeout: timeoutMs }, (err, stdout, stderr) => {
      if (err) {
        err.stdout = stdout;
        err.stderr = stderr;
        return reject(err);
      }
      resolve({ stdout, stderr });
    });
  });
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function parseSnapshotLine(line) {
  let parts = line.split("\t");
  if (parts.length < 3) {
    parts = line.split("\\t");
  }
  if (parts.length < 3) return null;

  const mtime = Number(parts.pop());
  const size = Number(parts.pop());
  const filePath = parts.join("\t");
  if (!filePath || !Number.isFinite(size) || !Number.isFinite(mtime)) return null;

  return {
    path: filePath,
    size,
    mtime,
  };
}

function toDisplayPath(absPath) {
  const resolved = path.resolve(absPath);
  const rel = path.relative(process.cwd(), resolved);
  const value = rel && !rel.startsWith("..") && !path.isAbsolute(rel) ? rel : resolved;
  return value.replace(/[\\/]+/g, "\\");
}

function makeHttpError(statusCode, message) {
  const err = new Error(message);
  err.statusCode = statusCode;
  return err;
}

function isPathInside(child, parent) {
  const relative = path.relative(parent, child);
  return relative === "" || (!!relative && !relative.startsWith("..") && !path.isAbsolute(relative));
}

function validateSnapshotId(snapshotId) {
  const id = String(snapshotId || "").trim();
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$/.test(id)) {
    throw makeHttpError(400, "Invalid snapshot id");
  }
  return id;
}

function resolveSnapshotDir(snapshotId) {
  const id = validateSnapshotId(snapshotId);
  const root = path.resolve(CONFIG.snapshotOutputDir);
  const snapshotDir = path.resolve(root, id);
  if (!isPathInside(snapshotDir, root)) {
    throw makeHttpError(400, "Invalid snapshot path");
  }
  return { id, root, snapshotDir };
}

async function captureFileSnapshot(containerName, roots = CONFIG.snapshotRoots) {
  const scanRoots = roots && roots.length ? roots : ["/root"];
  const quotedRoots = scanRoots.map(shellQuote).join(" ");
  const script = [
    "set -u",
    `for root in ${quotedRoots}; do`,
    '  if [ -e "$root" ]; then',
    '    find "$root" -type f -printf "%p\\t%s\\t%T@\\n" 2>/dev/null',
    "  fi",
    "done | sort",
  ].join("\n");

  const { stdout } = await execDocker(["exec", containerName, "sh", "-lc", script], {
    timeoutMs: CONFIG.snapshotTimeoutMs,
  });

  const files = new Map();
  for (const line of stdout.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const parsed = parseSnapshotLine(line);
    if (!parsed) continue;
    files.set(parsed.path, parsed);
  }

  return {
    capturedAt: Date.now(),
    roots: scanRoots,
    files,
    fileCount: files.size,
  };
}

function diffFileSnapshots(before, after) {
  const added = [];
  const modified = [];
  const deleted = [];

  for (const [filePath, afterMeta] of after.files.entries()) {
    const beforeMeta = before.files.get(filePath);
    if (!beforeMeta) {
      added.push({ ...afterMeta });
      continue;
    }
    if (beforeMeta.size !== afterMeta.size || beforeMeta.mtime !== afterMeta.mtime) {
      modified.push({
        ...afterMeta,
        beforeSize: beforeMeta.size,
        beforeMtime: beforeMeta.mtime,
      });
    }
  }

  for (const [filePath, beforeMeta] of before.files.entries()) {
    if (!after.files.has(filePath)) {
      deleted.push({ ...beforeMeta });
    }
  }

  const sortByPath = (a, b) => a.path.localeCompare(b.path);
  added.sort(sortByPath);
  modified.sort(sortByPath);
  deleted.sort(sortByPath);

  return {
    added,
    modified,
    deleted,
    summary: {
      beforeCount: before.fileCount,
      afterCount: after.fileCount,
      added: added.length,
      modified: modified.length,
      deleted: deleted.length,
      changed: added.length + modified.length + deleted.length,
    },
  };
}

function safeSnapshotRelativePath(containerPath) {
  const cleaned = String(containerPath || "")
    .replace(/^\/+/, "")
    .split("/")
    .map((part) => part.replace(/[^a-zA-Z0-9._-]/g, "_"))
    .filter(Boolean);
  return cleaned.length ? path.join(...cleaned) : "unknown-file";
}

async function copyChangedSnapshotFiles(containerName, changedFiles, filesDir) {
  const copied = [];
  const limited = changedFiles
    .filter((file) => file.size <= CONFIG.snapshotMaxFileBytes)
    .slice(0, CONFIG.snapshotCopyLimit);

  for (const file of limited) {
    const relativePath = safeSnapshotRelativePath(file.path);
    const destination = path.join(filesDir, relativePath);
    await fs.promises.mkdir(path.dirname(destination), { recursive: true });

    try {
      await execDocker(["cp", `${containerName}:${file.path}`, destination], {
        timeoutMs: CONFIG.snapshotTimeoutMs,
      });
      file.copiedTo = toDisplayPath(destination);
      copied.push({ path: file.path, copiedTo: file.copiedTo });
    } catch (err) {
      file.copyError = err.message;
      log.warn(`snapshot copy failed for ${file.path}: ${err.message}`);
    }
  }

  const skipped = changedFiles.length - limited.length;
  return { copied, skipped };
}

function toArchivePath(value) {
  const clean = String(value || "")
    .replace(/\\/g, "/")
    .replace(/^\/+/, "")
    .split("/")
    .filter((part) => part && part !== "." && part !== "..")
    .join("/");
  if (!clean) throw new Error("Invalid archive path");
  return clean;
}

function splitTarPath(archivePath) {
  const normalized = toArchivePath(archivePath);
  if (Buffer.byteLength(normalized) <= 100) {
    return { name: normalized, prefix: "" };
  }

  const parts = normalized.split("/");
  for (let i = parts.length - 1; i > 0; i -= 1) {
    const prefix = parts.slice(0, i).join("/");
    const name = parts.slice(i).join("/");
    if (Buffer.byteLength(prefix) <= 155 && Buffer.byteLength(name) <= 100) {
      return { name, prefix };
    }
  }

  throw new Error(`Archive path too long: ${normalized}`);
}

function writeTarString(buffer, value, offset, length) {
  const input = Buffer.from(String(value || ""), "utf8");
  input.copy(buffer, offset, 0, Math.min(input.length, length));
}

function writeTarOctal(buffer, value, offset, length) {
  const normalized = Math.max(0, Math.floor(Number(value) || 0));
  const octal = normalized.toString(8).slice(-(length - 1)).padStart(length - 1, "0");
  buffer.write(`${octal}\0`, offset, length, "ascii");
}

function createTarHeader({ archivePath, size, mtime, mode = 0o644 }) {
  const { name, prefix } = splitTarPath(archivePath);
  const header = Buffer.alloc(512, 0);

  writeTarString(header, name, 0, 100);
  writeTarOctal(header, mode, 100, 8);
  writeTarOctal(header, 0, 108, 8);
  writeTarOctal(header, 0, 116, 8);
  writeTarOctal(header, size, 124, 12);
  writeTarOctal(header, Math.floor(mtime || Date.now() / 1000), 136, 12);
  header.fill(0x20, 148, 156);
  header[156] = "0".charCodeAt(0);
  writeTarString(header, "ustar", 257, 6);
  writeTarString(header, "00", 263, 2);
  writeTarString(header, "root", 265, 32);
  writeTarString(header, "root", 297, 32);
  writeTarString(header, prefix, 345, 155);

  let checksum = 0;
  for (const byte of header) checksum += byte;
  const checksumValue = checksum.toString(8).padStart(6, "0");
  header.write(`${checksumValue}\0 `, 148, 8, "ascii");
  return header;
}

async function writeStreamChunk(stream, chunk) {
  if (!stream.write(chunk)) {
    await once(stream, "drain");
  }
}

async function addBufferToTar(stream, archivePath, data, mtime = Date.now() / 1000) {
  const body = Buffer.isBuffer(data) ? data : Buffer.from(String(data || ""), "utf8");
  await writeStreamChunk(stream, createTarHeader({ archivePath, size: body.length, mtime }));
  if (body.length) await writeStreamChunk(stream, body);
  const padding = (512 - (body.length % 512)) % 512;
  if (padding) await writeStreamChunk(stream, Buffer.alloc(padding, 0));
}

async function addFileToTar(stream, filePath, archivePath) {
  const stat = await fs.promises.stat(filePath);
  await writeStreamChunk(stream, createTarHeader({
    archivePath,
    size: stat.size,
    mtime: stat.mtimeMs / 1000,
    mode: stat.mode & 0o777,
  }));

  for await (const chunk of fs.createReadStream(filePath)) {
    await writeStreamChunk(stream, chunk);
  }

  const padding = (512 - (stat.size % 512)) % 512;
  if (padding) await writeStreamChunk(stream, Buffer.alloc(padding, 0));
}

async function listFilesRecursive(rootDir) {
  const files = [];
  let entries;
  try {
    entries = await fs.promises.readdir(rootDir, { withFileTypes: true });
  } catch (err) {
    if (err.code === "ENOENT") return files;
    throw err;
  }

  for (const entry of entries) {
    const entryPath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      files.push(...await listFilesRecursive(entryPath));
    } else if (entry.isFile()) {
      files.push(entryPath);
    }
  }
  return files.sort((a, b) => a.localeCompare(b));
}

async function getChangedFilesArchiveInfo(snapshotId) {
  const { id, snapshotDir } = resolveSnapshotDir(snapshotId);
  const filesDir = path.join(snapshotDir, "files");
  const reportPath = path.join(snapshotDir, "report.md");

  let stat;
  try {
    stat = await fs.promises.stat(filesDir);
  } catch (err) {
    if (err.code === "ENOENT") throw makeHttpError(404, "Snapshot files directory not found");
    throw err;
  }
  if (!stat.isDirectory()) throw makeHttpError(404, "Snapshot files directory not found");

  const files = await listFilesRecursive(filesDir);
  if (!files.length) {
    throw makeHttpError(404, "No copied added/modified files in this snapshot");
  }

  return {
    snapshotId: id,
    snapshotDir,
    filesDir,
    reportPath,
    files,
    archiveName: `login-changed-files-${id}.tar.gz`,
  };
}

async function streamChangedFilesArchive(infoOrSnapshotId, writable) {
  const info = typeof infoOrSnapshotId === "string"
    ? await getChangedFilesArchiveInfo(infoOrSnapshotId)
    : infoOrSnapshotId;
  const gzip = zlib.createGzip({ level: 9 });
  gzip.pipe(writable);

  try {
    try {
      const report = await fs.promises.readFile(info.reportPath);
      await addBufferToTar(gzip, "report.md", report);
    } catch (err) {
      if (err.code !== "ENOENT") throw err;
    }

    for (const filePath of info.files) {
      const relative = path.relative(info.filesDir, filePath);
      await addFileToTar(gzip, filePath, `files/${relative.replace(/\\/g, "/")}`);
    }

    await writeStreamChunk(gzip, Buffer.alloc(1024, 0));
    gzip.end();
    await finished(gzip);
  } catch (err) {
    gzip.destroy(err);
    throw err;
  }
}

function formatFileLine(file) {
  const suffix = file.copyError ? ` [copy failed: ${file.copyError}]` : "";
  return `  ${file.path}  [${file.size} bytes]${suffix}`;
}

function buildLoginSnapshotReport({ email, sessionId, containerName, roots, diff, output }) {
  const { summary } = diff;
  const lines = [
    "# AGY login container file snapshot",
    "",
    `Email: ${email}`,
    `Session: ${sessionId}`,
    `Container: ${containerName}`,
    `Roots: ${roots.join(", ")}`,
    `Generated at: ${new Date().toISOString()}`,
    "",
    `Sau login: ${summary.afterCount} files (added=${summary.added} modified=${summary.modified} deleted=${summary.deleted})`,
    "",
    `## THÊM MỚI (${summary.added})`,
    ...(diff.added.length ? diff.added.map(formatFileLine) : ["  Không có"]),
    "",
    `## THAY ĐỔI (${summary.modified})`,
    ...(diff.modified.length ? diff.modified.map(formatFileLine) : ["  Không có"]),
    "",
    `## ĐÃ XÓA (${summary.deleted})`,
    ...(diff.deleted.length ? diff.deleted.map(formatFileLine) : ["  Không có"]),
    "",
    "## Xuất ra",
    `- ${output.displayDir}`,
    "- report.md",
    "- files/",
    `- download: ${output.archiveName}`,
  ];
  return `${lines.join("\n")}\n`;
}

function snapshotTimestamp() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "").replace(/:/g, "-");
}

async function createLoginSnapshotReport({ containerName, sessionId, email, before, after }) {
  const diff = diffFileSnapshots(before, after);
  const snapshotDir = path.resolve(CONFIG.snapshotOutputDir, snapshotTimestamp());
  const filesDir = path.join(snapshotDir, "files");
  await fs.promises.mkdir(filesDir, { recursive: true });

  const afterChangedFiles = [...diff.added, ...diff.modified];
  const copyResult = await copyChangedSnapshotFiles(containerName, afterChangedFiles, filesDir);
  const snapshotId = path.basename(snapshotDir);

  const output = {
    snapshotId,
    dir: snapshotDir,
    report: path.join(snapshotDir, "report.md"),
    filesDir,
    displayDir: toDisplayPath(snapshotDir),
    displayReport: toDisplayPath(path.join(snapshotDir, "report.md")),
    displayFilesDir: toDisplayPath(filesDir),
    copied: copyResult.copied,
    copiedCount: copyResult.copied.length,
    skipped: copyResult.skipped,
    archiveName: `login-changed-files-${snapshotId}.tar.gz`,
    downloadUrl: `/api/login/snapshots/${encodeURIComponent(snapshotId)}/changed-files.tar.gz`,
  };

  const report = buildLoginSnapshotReport({
    email,
    sessionId,
    containerName,
    roots: after.roots,
    diff,
    output,
  });
  await fs.promises.writeFile(output.report, report, "utf8");

  return {
    generatedAt: Date.now(),
    roots: after.roots,
    before: {
      capturedAt: before.capturedAt,
      fileCount: before.fileCount,
    },
    after: {
      capturedAt: after.capturedAt,
      fileCount: after.fileCount,
    },
    summary: diff.summary,
    diff: {
      added: diff.added,
      modified: diff.modified,
      deleted: diff.deleted,
    },
    output,
  };
}

function getCodeFilePath(fifoPath) {
  return `${fifoPath}.code`;
}

async function isContainerRunning(containerName) {
  try {
    const { stdout } = await execDocker(["inspect", "-f", "{{.State.Running}}", containerName]);
    return stdout.trim() === "true";
  } catch (_) {
    return false;
  }
}

/**
 * Verify the `agy` binary actually resolves inside the container.
 *
 * Trên Azure, build agy có thể hỏng nhưng vẫn tạo image (lịch sử dùng
 * `|| true`). Khi đó container chạy bình thường nhưng KHÔNG có `agy` →
 * mọi login fail mơ hồ ("No auth URL within Ns"). Hàm này cho phép backend
 * phát hiện sớm và báo lỗi đúng nguyên nhân.
 *
 * Trả về: { ok, path, error }
 */
async function checkAgyBinary(containerName = CONFIG.containerName) {
  try {
    const { stdout } = await execDocker(
      [
        "exec",
        containerName,
        "sh",
        "-lc",
        'export PATH="/root/.local/bin:/usr/local/bin:$PATH"; command -v agy',
      ],
      { timeoutMs: 8000 },
    );
    const resolved = stdout.trim();
    if (resolved) {
      return { ok: true, path: resolved, error: null };
    }
    return {
      ok: false,
      path: null,
      error:
        "Binary 'agy' không tồn tại trong container agy-dev. Image có thể đã build hỏng (cài agy thất bại). " +
        "Hãy rebuild image agy-dev (docker compose build --no-cache agy-dev) — và trên Azure, xoá local buildx cache cho service này.",
    };
  } catch (err) {
    const cls = classifyDockerError(err);
    return {
      ok: false,
      path: null,
      error: `[${cls.code}] ${cls.hint || err.message}`,
    };
  }
}


/**
 * Ensure container is running. If not, run `docker compose up -d`.
 * Falls back gracefully if compose is not available.
 */
async function ensureContainerRunning(containerName = CONFIG.containerName) {
  // Probe environment first so we can return clean, actionable errors.
  const envStatus = await checkDockerEnv({ force: true });
  if (!envStatus.available) {
    throw new Error(`[${envStatus.error.code}] ${envStatus.error.hint}`);
  }
  if (!envStatus.daemonOk) {
    throw new Error(`[${envStatus.error.code}] ${envStatus.error.hint}`);
  }

  if (await isContainerRunning(containerName)) {
    return true;
  }
  log.warn(`Container ${containerName} not running. Trying 'docker compose up -d'...`);
  try {
    await execDocker(["compose", "up", "-d"], { timeoutMs: 60_000 });
  } catch (err) {
    const cls = classifyDockerError(err);
    log.err(`docker compose up failed: ${err.message}. Trying 'docker start ${containerName}'...`);
    try {
      await execDocker(["start", containerName]);
    } catch (e2) {
      const cls2 = classifyDockerError(e2);
      throw new Error(`Cannot start container ${containerName} [${cls2.code}]: ${cls2.hint || e2.message}`);
    }
  }
  // Re-check after a short delay
  await new Promise((r) => setTimeout(r, 1000));
  if (!(await isContainerRunning(containerName))) {
    throw new Error(`Container ${containerName} still not running after start attempt.`);
  }
  log.ok(`Container ${containerName} is running.`);
  return true;
}

// ─── FIFO management ──────────────────────────────────────────────────────────

async function createFifo(containerName, fifoPath) {
  // -p so it's idempotent if a previous run left the FIFO behind
  const codeFilePath = getCodeFilePath(fifoPath);
  await execDocker(["exec", containerName, "sh", "-lc", `rm -f "${fifoPath}" "${codeFilePath}" "${codeFilePath}.tmp" && mkfifo "${fifoPath}" && chmod 0600 "${fifoPath}"`]);
  log.step(`FIFO created: ${fifoPath}`);
}

async function cleanupFifo(containerName, fifoPath) {
  try {
    const codeFilePath = getCodeFilePath(fifoPath);
    await execDocker(["exec", containerName, "sh", "-lc", `rm -f "${fifoPath}" "${codeFilePath}" "${codeFilePath}.tmp"`]);
  } catch (err) {
    log.warn(`cleanupFifo failed for ${fifoPath}: ${err.message}`);
  }
}

// ─── Credential management ────────────────────────────────────────────────────

function _credentialExists(containerName, credentialPath) {
  return new Promise((resolve) => {
    const p = spawn("docker", ["exec", "-e", `AGY_CREDENTIAL_PATH=${credentialPath}`, containerName, "sh", "-lc", 'test -s "$AGY_CREDENTIAL_PATH"'], {
      stdio: ["ignore", "ignore", "ignore"],
    });
    p.on("error", () => resolve(false));
    p.on("close", (code) => resolve(code === 0));
  });
}

/**
 * Poll for credential file presence. Returns true if found before timeout.
 * Ported from wrapper.js#waitForContainerCredential.
 */
async function waitForCredential(
  containerName,
  credentialPath = CONFIG.credentialPath,
  timeoutMs = CONFIG.credentialCheckTimeoutMs,
  intervalMs = CONFIG.credentialCheckIntervalMs,
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await _credentialExists(containerName, credentialPath)) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}

async function readCredentialFile(containerName, credentialPath = CONFIG.credentialPath) {
  const { stdout } = await execDocker(["exec", containerName, "sh", "-lc", `cat "${credentialPath}"`], { timeoutMs: 10_000 });
  return stdout;
}

async function resetCredential(containerName, credentialPath = CONFIG.credentialPath) {
  try {
    await execDocker(["exec", containerName, "sh", "-lc", `rm -f "${credentialPath}"`]);
    log.ok(`Reset credential at ${credentialPath}`);
  } catch (err) {
    log.warn(`resetCredential failed: ${err.message}`);
  }
}

// ─── Spawn agy session ────────────────────────────────────────────────────────

/**
 * Spawn `docker exec ... /exec-wrapper.sh agy auth-wait` with all env vars
 * required by exec-wrapper.sh (FIFO + auth probe). Returns the child process.
 *
 * The caller is responsible for piping stdout/stderr through extractUrl.
 */
function spawnAgySession({ containerName, fifoPath, sessionId }) {
  const args = [
    "exec",
    "-e",
    `AGY_LOGIN_PROMPT=${CONFIG.authProbePrompt}`,
    "-e",
    `AGY_LOGIN_PRINT_TIMEOUT=${CONFIG.authProbeTimeout}`,
    "-e",
    `AGY_LOGIN_CODE_FIFO=${fifoPath}`,
    "-e",
    `AGY_LOGIN_CODE_FILE=${getCodeFilePath(fifoPath)}`,
    containerName,
    "/exec-wrapper.sh",
    "agy",
    "auth-wait",
  ];
  log.step(`Spawning agy session ${sessionId}: docker ${args.join(" ")}`);
  return spawn("docker", args, {
    stdio: ["pipe", "pipe", "pipe"],
    env: process.env,
  });
}

/**
 * Write the authorization code into the FIFO inside the container.
 * Ported from wrapper.js#writeAuthCodeToContainer. 10s timeout.
 */
function writeCodeToContainer(containerName, fifoPath, code) {
  const codeFilePath = getCodeFilePath(fifoPath);
  return execDocker(
    [
      "exec",
      "-e",
      `AGY_LOGIN_CODE=${code}`,
      "-e",
      `AGY_LOGIN_CODE_FILE=${codeFilePath}`,
      "-e",
      `AGY_LOGIN_CODE_FIFO=${fifoPath}`,
      containerName,
      "sh",
      "-lc",
      'umask 077; tmp="${AGY_LOGIN_CODE_FILE}.tmp"; printf "%s\\n" "$AGY_LOGIN_CODE" > "$tmp" && mv "$tmp" "$AGY_LOGIN_CODE_FILE"',
    ],
    { timeoutMs: CONFIG.codeWriteTimeoutMs },
  ).then(() => undefined);
}

module.exports = {
  CONFIG,
  ensureContainerRunning,
  isContainerRunning,
  checkAgyBinary,
  checkDockerEnv,
  createFifo,
  cleanupFifo,
  spawnAgySession,
  writeCodeToContainer,
  waitForCredential,
  readCredentialFile,
  resetCredential,
  captureFileSnapshot,
  createLoginSnapshotReport,
  getChangedFilesArchiveInfo,
  streamChangedFilesArchive,
  acquireMutex,
  releaseMutex,
  getCodeFilePath,
};
