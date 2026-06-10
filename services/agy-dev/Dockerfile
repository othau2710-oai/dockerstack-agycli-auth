# syntax=docker/dockerfile:1.7
FROM node:20-slim

# ── Layer 1: minimal system deps ────────────────────────────────
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl ca-certificates bash expect \
  && rm -rf /var/lib/apt/lists/*

# ── Layer 2: Antigravity CLI (agy) — layer phụ thuộc network ─────
# NOTE: install.sh sets up `agy` binary at /root/.local/bin/agy
#
# 💡 Bump AGYCLI_CACHE_BUILD (trong .env) để force rebuild layer này và tải agy mới nhất.
ARG AGY_INSTALL_URL="https://antigravity.google/cli/install.sh"
ARG AGYCLI_CACHE_BUILD="2026-06-10"
COPY agy-install.sh /tmp/agy-install.sh
RUN AGY_INSTALL_URL="${AGY_INSTALL_URL}" \
  AGYCLI_CACHE_BUILD="${AGYCLI_CACHE_BUILD}" \
  bash /tmp/agy-install.sh

# ── Layer 3: wrapper script (đổi khi exec-wrapper.sh đổi) ───────
COPY exec-wrapper.sh /exec-wrapper.sh
RUN chmod +x /exec-wrapper.sh

RUN mkdir -p /root/.gemini/antigravity-cli

WORKDIR /app

# Keep container alive (stdin_open + tty are set in docker-compose)
CMD ["tail", "-f", "/dev/null"]