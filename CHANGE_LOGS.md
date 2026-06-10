# CHANGE LOGS (Developer-facing)

---

## [2.1.0] — 2026-06-10

### Fixed — Auth fails on Azure pipeline (works on GitHub Actions)

- **`services/agy-dev/Dockerfile`** — root cause of the Azure-only auth failures.
  The `agy` CLI install used `curl … | bash || true`; the `|| true` **silently
  swallowed install failures**, producing an image with **no working `agy`
  binary**. Combined with Azure's weekly-rotated local buildx cache, a single
  bad-network build poisoned the layer for the whole week → consistent Azure
  failures while GitHub's scoped `type=gha` cache rebuilt cleanly.
  Now: **retry up to 3×, no `|| true`, and verify `command -v agy` at
  build-time** → a broken install **fails the build loudly** instead of caching
  a silently-broken image. Install URL overridable via `--build-arg AGY_INSTALL_URL`.
- **`services/agy-dev/exec-wrapper.sh`** — when `agy` is missing, emit a clear
  `__AGY_BINARY_MISSING__` sentinel + exit 127 instead of `exec`-ing a
  non-existent path (which produced opaque errors). Default print-timeout
  raised `1s → 5s` (1s was too tight on cold Azure agents).
- **`services/app/src/services/dockerService.js`** — `authProbeTimeout` default
  `1s → 5s`; new configurable `urlWaitTimeoutMs` (env `AGY_URL_WAIT_TIMEOUT_MS`,
  default 60s); new `checkAgyBinary()` pre-flight that verifies `agy` resolves
  inside the container.
- **`services/app/src/routes/login.js`** — pre-flight `checkAgyBinary` before
  spawning; detects the `__AGY_BINARY_MISSING__` sentinel; the previously
  **hardcoded 30s** URL-wait is now configurable and, on timeout, **attaches a
  sanitized (token-redacted) tail of stdout/stderr** so the real cause is
  visible instead of just "No auth URL within 30s".
- **`compose.apps.yml`** — maps new `AGY_LOGIN_PRINT_TIMEOUT` /
  `AGY_URL_WAIT_TIMEOUT_MS` to `app`; adds an `agy-dev` healthcheck that fails
  if the `agy` binary is absent.
- Note: `DOTENVRTDB_URL` was **not** the cause — it is an Azure DevOps secret
  variable (works as designed); `urlExtract.js` regex left untouched.

### Added / Changed — rclone: per-service, per-path configuration

- **Multi-path config (indexed vars, 1A)** — `.env` now supports
  `RCLONE_PATH_<N>_LOCAL / _REMOTE / _MODE / _GATE` for N = 1..10.
  - **MODE per path (2A):** `restore | sync | both` — each path can pull-only,
    push-only, or both, independently.
  - **Per-path gate (3A):** `GATE=true` → app/litestream wait for that path's
    restore before starting; `GATE=false` → restored in the background, app
    starts immediately.
- **Backward compatible:** leaving all `RCLONE_PATH_*` empty falls back to the
  old single-path behavior using `RCLONE_REMOTE_TARGET` + `RCLONE_LOCAL_PATH`
  (mode=both, gate=true). Existing `.env` files keep working unchanged.
- **`services/rclone/lib.sh`** (new) — shared path-collection/mode helpers,
  read by all three rclone scripts. Reads both `STACK_RCLONE_*` (forwarded by
  compose) and plain `RCLONE_*`.
- **`services/rclone/init.sh`** — validates the remote of **every** configured
  path against the rclone.conf.
- **`services/rclone/restore.sh`** — loops over restore-capable paths; takes
  `--gated-only` / `--non-gated-only` filter so the same script serves both the
  blocking restore container and the background restore in the sidecar.
- **`services/rclone/sync.sh`** — first restores non-gated paths in the
  background (non-blocking), then continuously syncs all `sync|both` paths;
  per-path audit. Idles (no busy loop) if no path needs syncing.
- **`docker-compose/compose.rclone.yml`** — forwards indexed path vars (1..10)
  via YAML anchors under the `STACK_RCLONE_*` prefix (avoids rclone's
  auto-mapping of `RCLONE_*` env → CLI flags); `rclone-restore` now runs with
  `--gated-only`; `rclone-sync` also mounts `restore.sh` + `lib.sh`.
- **`compose.rclone-gate.yml`** unchanged — app/litestream gate on
  `rclone-restore`, which now only processes `GATE=true` paths (= per-path gate).
- **`.env.example`** — documented the multi-path block + the two new auth
  timing vars (`AGYCLI_AUTH_AGY_LOGIN_PRINT_TIMEOUT`,
  `AGYCLI_AUTH_AGY_URL_WAIT_TIMEOUT_MS`).

---

## [2.0.0] — 2026-04-09

### Breaking Changes

- `docker-compose.yml` split into 4 module files — must use `docker-compose/scripts/dc.sh` (or `-f docker-compose/compose.core.yml -f docker-compose/compose.ops.yml -f docker-compose/compose.access.yml -f compose.apps.yml`) instead of plain `docker compose`
- Env var renames: `DOMAIN` replaces individual `SUBDOMAIN_*` vars; `STACK_NAME` replaces `COMPOSE_PROJECT_NAME`; `PROJECT_NAME` is new (required)
- `TAILSCALE_CLIENT_SECRET` → `TAILSCALE_AUTHKEY` (standardised Tailscale env naming)
- `APP_PORT` now drives the app container port directly; `SUBDOMAIN_APP`, `SUBDOMAIN_DOZZLE`, etc. removed

### Added

- **`docker-compose/scripts/dc.sh`** — main orchestrator: loads `.env`, reads `ENABLE_*` flags, builds `--profile` args, calls all 4 compose files in one command
- **`docker-compose/compose.core.yml`** — caddy + cloudflared, network + volumes definition; always-on
- **`docker-compose/compose.ops.yml`** — dozzle, filebrowser, webssh, webssh-windows; all profile-gated
- **`docker-compose/compose.access.yml`** — tailscale-linux, tailscale-windows; profile-gated
- **`compose.apps.yml`** — parameterised app service (`APP_IMAGE` + `APP_PORT`)
- **`docker-compose/scripts/up.sh` / `docker-compose/scripts/down.sh` / `docker-compose/scripts/logs.sh`** — one-liner shortcuts wrapping `dc.sh`
- **`docker-compose/scripts/validate-env.js`** — checks required vars, format validation (bcrypt, domain, port), subdomain preview
- **`docker-compose/scripts/validate-ts.js`** — Tailscale auth key format check + optional expiry lookup via TS API
- **`docker-compose/scripts/validate-compose.js`** — runs `docker compose config` across all 4 files to catch YAML errors
- **`npm run dockerapp-validate:all`** — combined validation pipeline (env → compose → TS)
- **`docs/DEPLOY.md`** — full deployment guide with mermaid flow diagrams, use cases, security checklist
- Subdomain auto-convention: all routes derived from `${PROJECT_NAME}.${DOMAIN}` pattern
- `DC_VERBOSE=1` debug flag for `docker-compose/scripts/dc.sh`
- `HEALTH_PATH` env to customise healthcheck endpoint per image

### Changed

- Image versions pinned (caddy `2.9.1-alpine`, cloudflared `2025.1.0`, dozzle `v8.x`, filebrowser `v2.30.0`, tailscale `stable`)
- Caddy `CADDY_INGRESS_NETWORKS` now uses `${STACK_NAME}_net` (was `app_net`)
- Network name: `${STACK_NAME:-mystack}_net` (dynamic, avoids conflicts between stacks)
- GitHub Actions and Azure Pipelines updated to call `docker-compose/scripts/dc.sh up` instead of bare `docker compose up`
- `detect-os.sh` no longer writes `COMPOSE_PROFILES` (profiles now fully managed by `docker-compose/scripts/dc.sh`)
- `.env.example` fully rewritten to match new schema

### Removed

- Monolithic `docker-compose.yml` (replaced by 4 module files)
- `SUBDOMAIN_APP`, `SUBDOMAIN_DOZZLE`, `SUBDOMAIN_FILEBROWSER`, `SUBDOMAIN_WEBSSH` env vars
- `TAILSCALE_CLIENT_SECRET` (use `TAILSCALE_AUTHKEY`)
- Hardcoded `build: ./services/app` in compose (now `APP_IMAGE` param)
- `scripts/generate-cf-config.js` and the generated-config workflow (maintain `cloudflared/config.yml` manually)

---
