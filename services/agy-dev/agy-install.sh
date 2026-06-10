#!/usr/bin/env bash
# agy-install.sh — Tải và cài Antigravity CLI (agy)
# Biến đầu vào (truyền qua env):
#   AGY_INSTALL_URL  — URL của install.sh (default: https://antigravity.google/cli/install.sh)
#   AGYCLI_CACHE_BUILD   — Dùng để bust Docker cache, không ảnh hưởng logic cài đặt
set -eu

AGY_INSTALL_URL="${AGY_INSTALL_URL:-https://antigravity.google/cli/install.sh}"
export PATH="/root/.local/bin:/usr/local/bin:${PATH}"

echo "==> [agy-install] cache bust: ${AGYCLI_CACHE_BUILD:-unset}"
echo "==> [agy-install] source: ${AGY_INSTALL_URL}"

# 1. Download install.sh với retry
downloaded=0
for attempt in 1 2 3; do
  echo "==> [agy-install] download attempt ${attempt}/3..."
  if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 \
      "${AGY_INSTALL_URL}" -o /tmp/_agy-upstream-install.sh; then
    downloaded=1
    break
  fi
  echo "==> [agy-install] attempt ${attempt} failed, retrying..." >&2
  sleep 3
done

if [ "${downloaded}" != "1" ]; then
  echo "[agy-install] FAILED: Tai install.sh that bai sau 3 lan thu." >&2
  exit 1
fi

# 2. Chạy install.sh
# install.sh có thể exit non-zero do warning PATH dù cài thành công
# → dùng || true, verify binary bên dưới mới là nguồn sự thật
bash /tmp/_agy-upstream-install.sh || true
rm -f /tmp/_agy-upstream-install.sh

# 3. Verify binary
if ! command -v agy >/dev/null 2>&1; then
  echo "[agy-install] FAILED: install.sh chay xong nhung KHONG tim thay binary agy trong PATH." >&2
  echo "  PATH=${PATH}" >&2
  ls -la /usr/local/bin /root/.local/bin 2>/dev/null || true
  exit 1
fi

AGY_VERSION=$(agy --version 2>/dev/null || echo "unknown")
echo "==> [agy-install] OK: agy ${AGY_VERSION} at $(command -v agy)"