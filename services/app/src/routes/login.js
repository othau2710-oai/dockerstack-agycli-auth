'use strict';

/**
 * routes/login.js
 * Endpoints:
 *   POST /api/login/start          — kick off agy session, capture auth URL
 *   GET  /api/login/stream/:id     — SSE channel for that session
 *   POST /api/login/submit-code    — feed auth code back into the container
 *   POST /api/login/reset          — kill session + clean up
 */

const express = require('express');
const docker = require('../services/dockerService');
const sessions = require('../services/sessionManager');
const firebase = require('../services/firebaseService');
const { extractUrl, addEmailHint } = require('../utils/urlExtract');
const { isValidEmail, isValidSessionId } = require('../utils/sanitize');

const router = express.Router();

const log = {
  info: (msg) => console.log(`ℹ  [LOGIN] ${msg}`),
  warn: (msg) => console.warn(`⚠  [LOGIN] ${msg}`),
  err:  (msg) => console.error(`✗  [LOGIN] ${msg}`),
  ok:   (msg) => console.log(`✓  [LOGIN] ${msg}`),
};

function emitAuthLog(sessionId, level, message, details = null) {
  if (level === 'error') log.err(`[${sessionId}] ${message}`);
  else if (level === 'warning') log.warn(`[${sessionId}] ${message}`);
  else if (level === 'success') log.ok(`[${sessionId}] ${message}`);
  else log.info(`[${sessionId}] ${message}`);

  sessions.appendLog(sessionId, { level, message, details });
}

// ─── POST /api/login/start ───────────────────────────────────────────────────

router.post('/start', async (req, res) => {
  const { email, sessionId } = req.body || {};

  if (!isValidEmail(email)) {
    return res.status(400).json({ error: 'Invalid email format' });
  }
  if (!isValidSessionId(sessionId)) {
    return res.status(400).json({ error: 'Invalid sessionId (alphanumeric/_- only, 8-128 chars)' });
  }

  if (sessions.getSession(sessionId)) {
    return res.status(409).json({ error: 'Session already exists' });
  }

  // Acquire global mutex (Option A) — only one active login at a time
  await docker.acquireMutex(sessionId);

  try {
    await docker.ensureContainerRunning();
  } catch (err) {
    docker.releaseMutex(sessionId);
    log.err(`ensureContainerRunning failed: ${err.message}`);
    return res.status(500).json({ error: `Container not available: ${err.message}` });
  }

  // ── Pre-flight: agy binary phải tồn tại trong container ──────────────────
  // Trên Azure, image agy-dev có thể build hỏng nhưng vẫn chạy (lịch sử dùng
  // `|| true` khi cài agy). Khi đó login luôn fail với thông báo mơ hồ
  // "No auth URL". Check sớm để báo đúng nguyên nhân & gợi ý rebuild.
  try {
    const bin = await docker.checkAgyBinary(docker.CONFIG.containerName);
    if (!bin.ok) {
      docker.releaseMutex(sessionId);
      log.err(`agy binary check failed: ${bin.error}`);
      return res.status(500).json({ error: `agy CLI unavailable: ${bin.error}` });
    }
    log.ok(`agy binary resolved at ${bin.path}`);
  } catch (err) {
    // Không chặn cứng nếu việc check gặp lỗi bất thường — chỉ cảnh báo.
    log.warn(`agy binary check errored (continuing): ${err.message}`);
  }

  const session = sessions.createSession({ sessionId, email });
  emitAuthLog(sessionId, 'info', `Container ${docker.CONFIG.containerName} is running; preparing auth session.`);

  try {
    emitAuthLog(sessionId, 'info', `Creating code FIFO at ${session.fifoPath}.`);
    await docker.createFifo(docker.CONFIG.containerName, session.fifoPath);
  } catch (err) {
    docker.releaseMutex(sessionId);
    sessions.destroySession(sessionId, { reason: 'fifo_failed' });
    return res.status(500).json({ error: `Failed to create FIFO: ${err.message}` });
  }

  // Reset old credential so we get a fresh OAuth flow each time
  emitAuthLog(sessionId, 'info', `Removing old credential at ${docker.CONFIG.credentialPath}.`);
  await docker.resetCredential(docker.CONFIG.containerName);

  // Spawn the agy session
  emitAuthLog(sessionId, 'info', 'Starting agy auth process and waiting for OAuth URL.');
  const child = docker.spawnAgySession({
    containerName: docker.CONFIG.containerName,
    fifoPath: session.fifoPath,
    sessionId,
  });
  session.childProcess = child;
  sessions.updateStatus(sessionId, 'waiting_url');

  // Process stdout/stderr — search for the auth URL
  function handleChunk(chunk, isStderr) {
    const text = chunk.toString('utf8');
    if (isStderr) session.stderrBuf += text;
    else session.stdoutBuf += text;

    // Try fresh chunk first, fall back to combined buffer once we still have no URL
    if (!session.authUrl) {
      const found = extractUrl(text)
        || extractUrl(session.stdoutBuf + '\n' + session.stderrBuf);
      if (found) {
        const finalUrl = addEmailHint(found, session.email);
        session.authUrl = finalUrl;
        sessions.updateStatus(sessionId, 'url_ready', { authUrl: finalUrl });
        sessions.emitSSE(sessionId, { type: 'auth_url', url: finalUrl });
        emitAuthLog(sessionId, 'success', 'Auth URL captured with email login_hint.');
        log.ok(`Auth URL captured for session ${sessionId}: ${finalUrl}`);
      }
    }

    // Detect known error patterns from agy
    if (/timed out waiting for response/i.test(text)
        || /authentication (?:timed out|interrupted)/i.test(text)) {
      // wrapper.js treats "timed out waiting for response" as benign (auth probe
      // satisfied) — we just log it. The SSE consumer can still see status.
      log.warn(`agy notice for ${sessionId}: ${text.trim().slice(0, 200)}`);
    }

    // Sentinel từ exec-wrapper.sh khi binary `agy` không tồn tại trong image.
    // Báo lỗi đúng nguyên nhân ngay thay vì để người dùng chờ hết timeout.
    if (text.includes('__AGY_BINARY_MISSING__') && session.status !== 'success' && session.status !== 'error') {
      sessions.updateStatus(sessionId, 'error');
      sessions.emitSSE(sessionId, {
        type: 'error',
        message:
          "agy CLI không có trong container agy-dev (image build hỏng). " +
          "Rebuild image: docker compose build --no-cache agy-dev. " +
          "Trên Azure, xoá local buildx cache cho agy-dev rồi build lại.",
      });
      emitAuthLog(sessionId, 'error', 'agy binary missing inside container (build broken).');
    }
  }

  child.stdout.on('data', (c) => handleChunk(c, false));
  child.stderr.on('data', (c) => handleChunk(c, true));

  child.on('close', (code) => {
    log.info(`agy child closed for ${sessionId} (code=${code})`);
    if (session.status !== 'success' && session.status !== 'error') {
      // If we never reached success but child ended, surface a soft warning.
      // Keep session alive so the SSE consumer can still get a final message.
      sessions.emitSSE(sessionId, {
        type: 'status',
        stage: session.status,
        note: `agy process ended (code=${code})`,
      });
    }
  });

  child.on('error', (err) => {
    log.err(`agy spawn error for ${sessionId}: ${err.message}`);
    sessions.emitSSE(sessionId, { type: 'error', message: err.message });
    sessions.updateStatus(sessionId, 'error');
  });

  // Configurable safety timeout: nếu chưa có URL, emit lỗi KÈM CHẨN ĐOÁN
  // (trích đoạn stdout/stderr đã ẩn token) để lộ nguyên nhân thật, thay vì
  // chỉ "No auth URL within 30s" như trước. Timeout cấu hình qua
  // AGY_URL_WAIT_TIMEOUT_MS (mặc định 60s) — môi trường chậm (Azure) cần dài hơn.
  const urlWaitMs = docker.CONFIG.urlWaitTimeoutMs || 60_000;
  setTimeout(() => {
    const s = sessions.getSession(sessionId);
    if (s && !s.authUrl && s.status !== 'success' && s.status !== 'error') {
      const waitSec = Math.round(urlWaitMs / 1000);
      const diag = buildAuthDiagnostics(s);
      log.err(`No auth URL for ${sessionId} within ${waitSec}s. stdout/stderr tail:\n${diag.text}`);
      sessions.emitSSE(sessionId, {
        type: 'error',
        message:
          `No auth URL detected within ${waitSec}s. ` +
          (diag.hint ? `${diag.hint} ` : '') +
          'Xem chi tiết log bên dưới hoặc thử reset rồi bắt đầu lại.',
        details: { diagnostics: diag.text },
      });
      emitAuthLog(sessionId, 'error', `Timeout chờ OAuth URL (${waitSec}s).`, { diagnostics: diag.text });
    }
  }, urlWaitMs);

  return res.json({ success: true, sessionId });
});

// Ẩn token/secret rồi trả về phần đuôi stdout/stderr để chẩn đoán khi timeout.
function redactSecrets(text) {
  return String(text || '')
    // OAuth/credential token: chuỗi dài liên tục → rút gọn
    .replace(/([A-Za-z0-9_-]{40,})/g, (m) => `${m.slice(0, 6)}…[${m.length} chars redacted]`)
    // Tham số nhạy cảm trong URL
    .replace(/([?&](?:code|token|access_token|refresh_token|client_secret)=)[^&\s]+/gi, '$1[redacted]');
}

function buildAuthDiagnostics(session) {
  const out = redactSecrets(session.stdoutBuf || '').trim();
  const err = redactSecrets(session.stderrBuf || '').trim();
  const tail = (s) => (s ? s.split(/\r?\n/).slice(-20).join('\n') : '(empty)');
  let hint = '';
  const combined = `${out}\n${err}`;
  if (/__AGY_BINARY_MISSING__/.test(combined)) {
    hint = 'Nguyên nhân: binary `agy` không có trong container (image build hỏng) — rebuild agy-dev.';
  } else if (!out && !err) {
    hint = 'agy không in ra gì — có thể container/agy không khởi động đúng. Kiểm tra `docker logs agy-dev`.';
  }
  return {
    hint,
    text: `--- stdout (tail) ---\n${tail(out)}\n\n--- stderr (tail) ---\n${tail(err)}`,
  };
}

// ─── GET /api/login/stream/:sessionId ────────────────────────────────────────

router.get('/stream/:sessionId', (req, res) => {
  const { sessionId } = req.params;
  if (!isValidSessionId(sessionId)) {
    return res.status(400).end();
  }
  const session = sessions.getSession(sessionId);
  if (!session) {
    return res.status(404).end();
  }

  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders?.();
  res.write('retry: 3000\n\n');

  sessions.attachSSE(sessionId, res);

  const heartbeat = setInterval(() => {
    try { res.write(`: ping ${Date.now()}\n\n`); } catch (_) {}
  }, 15_000);

  req.on('close', () => {
    clearInterval(heartbeat);
    sessions.detachSSE(sessionId);
    log.info(`SSE client disconnected for ${sessionId}`);
  });
});

// ─── GET /api/login/snapshots/:snapshotId/changed-files.tar.gz ──────────────

router.get('/snapshots/:snapshotId/changed-files.tar.gz', async (req, res) => {
  try {
    const info = await docker.getChangedFilesArchiveInfo(req.params.snapshotId);
    res.set({
      'Content-Type': 'application/gzip',
      'Content-Disposition': `attachment; filename="${info.archiveName}"`,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    });
    await docker.streamChangedFilesArchive(info, res);
  } catch (err) {
    if (res.headersSent) {
      res.destroy(err);
      return;
    }
    res.status(err.statusCode || 500).json({ error: err.message || 'Download failed' });
  }
});

// ─── POST /api/login/submit-code ─────────────────────────────────────────────

router.post('/submit-code', async (req, res) => {
  const { sessionId, code } = req.body || {};
  if (!isValidSessionId(sessionId)) {
    return res.status(400).json({ error: 'Invalid sessionId' });
  }
  if (!code || typeof code !== 'string' || code.length < 4) {
    return res.status(400).json({ error: 'Invalid auth code' });
  }

  const session = sessions.getSession(sessionId);
  if (!session) return res.status(404).json({ error: 'Session not found' });
  if (session.status !== 'url_ready' && session.status !== 'waiting_code') {
    return res.status(409).json({
      error: `Session not ready for code (status=${session.status})`,
    });
  }

  sessions.updateStatus(sessionId, 'waiting_code');
  emitAuthLog(sessionId, 'info', `Grant auth code started for container ${docker.CONFIG.containerName}.`);

  let beforeSnapshot = null;
  try {
    emitAuthLog(sessionId, 'info', `Taking before snapshot: ${docker.CONFIG.snapshotRoots.join(', ')}.`);
    beforeSnapshot = await docker.captureFileSnapshot(docker.CONFIG.containerName);
    emitAuthLog(sessionId, 'success', `Before snapshot captured: ${beforeSnapshot.fileCount} files.`);
  } catch (err) {
    emitAuthLog(sessionId, 'warning', `Before snapshot failed: ${err.message}`);
  }

  try {
    emitAuthLog(sessionId, 'info', `Writing auth code handoff file for ${session.fifoPath}.`);
    await docker.writeCodeToContainer(
      docker.CONFIG.containerName,
      session.fifoPath,
      code.trim(),
    );
  } catch (err) {
    log.err(`writeCodeToContainer failed for ${sessionId}: ${err.message}`);
    sessions.emitSSE(sessionId, { type: 'error', message: `Failed to submit code: ${err.message}` });
    return res.status(500).json({ error: err.message });
  }

  log.ok(`Code submitted for ${sessionId}; polling for credential...`);
  emitAuthLog(sessionId, 'info', `Code submitted; polling credential at ${docker.CONFIG.credentialPath}.`);
  const ok = await docker.waitForCredential(docker.CONFIG.containerName);
  if (!ok) {
    sessions.emitSSE(sessionId, {
      type: 'error',
      message: 'Credential file did not appear within 20s. The code may be wrong.',
    });
    return res.status(504).json({ error: 'Credential not detected (timeout). Wrong code?' });
  }
  emitAuthLog(sessionId, 'success', 'Credential file detected inside container.');

  let raw;
  try {
    emitAuthLog(sessionId, 'info', 'Reading credential file from container.');
    raw = await docker.readCredentialFile(docker.CONFIG.containerName);
  } catch (err) {
    sessions.emitSSE(sessionId, { type: 'error', message: `Read credential failed: ${err.message}` });
    return res.status(500).json({ error: err.message });
  }

  let snapshotReport = null;
  if (beforeSnapshot) {
    try {
      emitAuthLog(sessionId, 'info', `Taking after snapshot and writing report to ${docker.CONFIG.snapshotOutputDir}.`);
      const afterSnapshot = await docker.captureFileSnapshot(docker.CONFIG.containerName);
      snapshotReport = await docker.createLoginSnapshotReport({
        containerName: docker.CONFIG.containerName,
        sessionId,
        email: session.email,
        before: beforeSnapshot,
        after: afterSnapshot,
      });
      sessions.setLoginSnapshot(sessionId, snapshotReport);
      emitAuthLog(sessionId, 'success', `Snapshot report ready: ${snapshotReport.output.displayDir}.`, {
        summary: snapshotReport.summary,
        output: snapshotReport.output,
      });
    } catch (err) {
      emitAuthLog(sessionId, 'warning', `After snapshot/report failed: ${err.message}`);
    }
  }

  let key;
  try {
    emitAuthLog(sessionId, 'info', `Saving token for ${session.email} to Firebase.`);
    key = await firebase.saveToken(session.email, raw, sessionId);
  } catch (err) {
    log.err(`Firebase saveToken failed: ${err.message}`);
    sessions.emitSSE(sessionId, { type: 'error', message: `Firebase save failed: ${err.message}` });
    return res.status(500).json({ error: `Firebase save failed: ${err.message}` });
  }

  sessions.updateStatus(sessionId, 'success', { key });
  sessions.emitSSE(sessionId, {
    type: 'token_saved',
    email: session.email,
    key,
    savedAt: Date.now(),
    snapshot: snapshotReport,
  });

  // Cleanup
  await docker.cleanupFifo(docker.CONFIG.containerName, session.fifoPath);
  if (session.childProcess) {
    try { session.childProcess.kill('SIGTERM'); } catch (_) {}
  }
  docker.releaseMutex(sessionId);
  // Defer destroy briefly so the SSE consumer receives the success event
  setTimeout(() => sessions.destroySession(sessionId, { reason: 'success' }), 2000);

  return res.json({ success: true, key, email: session.email });
});

// ─── POST /api/login/reset ────────────────────────────────────────────────────

router.post('/reset', async (req, res) => {
  const { sessionId } = req.body || {};
  if (!isValidSessionId(sessionId)) {
    return res.status(400).json({ error: 'Invalid sessionId' });
  }
  const session = sessions.getSession(sessionId);
  if (!session) return res.status(404).json({ error: 'Session not found' });

  if (session.childProcess) {
    try { session.childProcess.kill('SIGTERM'); } catch (_) {}
  }
  await docker.cleanupFifo(docker.CONFIG.containerName, session.fifoPath).catch(() => {});
  await docker.resetCredential(docker.CONFIG.containerName).catch(() => {});
  docker.releaseMutex(sessionId);
  sessions.destroySession(sessionId, { reason: 'reset' });
  return res.json({ success: true });
});

module.exports = router;
