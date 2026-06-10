#!/bin/sh
# ================================================================
#  rclone sync.sh — Sidecar (multi-path)
#
#  Hai nhiệm vụ:
#    1. RESTORE NỀN (non-gated): với path GATE=false có mode bao gồm
#       'restore', kéo remote→local một lần lúc start. KHÔNG block app
#       (app chỉ chờ rclone-restore lo các path GATE=true).
#    2. SYNC LIÊN TỤC: mỗi RCLONE_SYNC_INTERVAL_SEC giây, push local→remote
#       cho mọi path có mode bao gồm 'sync'. Mỗi RCLONE_AUDIT_EVERY lần
#       chạy `rclone check` để verify parity.
# ================================================================
set -e

# shellcheck source=/scripts/lib.sh
. /scripts/lib.sh

SYNC_INTERVAL="$(_env_get RCLONE_SYNC_INTERVAL_SEC 30)"
LOG_LEVEL="$(_env_get RCLONE_LOG_LEVEL INFO)"
DRY_RUN="$(_env_get RCLONE_DRY_RUN false)"
EXTRA_FLAGS="$(_env_get RCLONE_EXTRA_FLAGS)"
TRANSFERS="$(_env_get RCLONE_TRANSFERS 8)"
CHECKERS="$(_env_get RCLONE_CHECKERS 16)"
AUDIT_EVERY="$(_env_get RCLONE_AUDIT_EVERY 10)"
BWLIMIT="$(_env_get RCLONE_BWLIMIT)"

START_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

echo "================================================================="
echo " RCLONE-SYNC  ::  local → remote (continuous sidecar, multi-path)"
echo " Started at   : $START_TS"
echo " Interval     : ${SYNC_INTERVAL}s"
echo " Transfers    : $TRANSFERS / Checkers: $CHECKERS"
echo " Log level    : $LOG_LEVEL"
echo " Dry run      : $DRY_RUN"
echo " Audit every  : ${AUDIT_EVERY} runs"
[ -n "$BWLIMIT" ]     && echo " Bw limit     : $BWLIMIT"
[ -n "$EXTRA_FLAGS" ] && echo " Extra flags  : $EXTRA_FLAGS"
echo "================================================================="

# ── Sanity ───────────────────────────────────────────────────────
[ ! -f "$CONFIG_PATH" ] && { echo "[FATAL] Thiếu $CONFIG_PATH"; exit 1; }

rclone_collect_paths
if [ "${RCLONE_PATH_COUNT:-0}" -eq 0 ]; then
  echo "[FATAL] Không có path nào được cấu hình."
  exit 1
fi
rclone_print_paths

# ── Build flags ──────────────────────────────────────────────────
DRY_FLAG=""
[ "$DRY_RUN" = "true" ] && DRY_FLAG="--dry-run"
BW_FLAG=""
[ -n "$BWLIMIT" ] && BW_FLAG="--bwlimit $BWLIMIT"

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB", u);
    i=1; while (b>=1024 && i<5) { b/=1024; i++ }
    printf "%.2f %s", b, u[i]
  }'
}

# ── 1. RESTORE NỀN cho path non-gated restore-capable ────────────
echo ""
echo "── BACKGROUND RESTORE (non-gated paths) ─────────────────────────"
NONGATED_RESTORE=0
i=1
while [ "$i" -le "$RCLONE_PATH_COUNT" ]; do
  GATE="$(rclone_path_field "$i" GATE)"
  if rclone_mode_wants "$i" restore && [ "$GATE" != "true" ]; then
    NONGATED_RESTORE=1
  fi
  i=$((i + 1))
done
if [ "$NONGATED_RESTORE" -eq 1 ]; then
  echo "  Có path non-gated cần restore nền → chạy restore.sh --non-gated-only"
  # restore.sh dùng chung lib + collect_paths; chạy nền không block sync loop.
  sh /scripts/restore.sh --non-gated-only || \
    echo "  [WARN] Restore nền (non-gated) gặp lỗi — sync loop vẫn tiếp tục."
else
  echo "  (không có path non-gated restore-capable)"
fi

# ── Sync 1 path ──────────────────────────────────────────────────
run_one_sync_path() {
  IDX="$1"
  N="$2"
  LOCAL_PATH="$(rclone_path_field "$IDX" LOCAL)"
  REMOTE_TARGET="$(rclone_path_field "$IDX" REMOTE)"

  if [ ! -d "$LOCAL_PATH" ]; then
    mkdir -p "$LOCAL_PATH" 2>/dev/null || true
  fi

  L_FILES=$(find "$LOCAL_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')
  : "${L_FILES:=0}"
  echo "  ── path #$IDX  $LOCAL_PATH → $REMOTE_TARGET  ($L_FILES files local)"

  set +e
  rclone --config "$CONFIG_PATH" sync "$LOCAL_PATH" "$REMOTE_TARGET" \
    --log-level "$LOG_LEVEL" \
    --stats 10s \
    --stats-one-line \
    --transfers "$TRANSFERS" \
    --checkers "$CHECKERS" \
    --create-empty-src-dirs \
    --update \
    $BW_FLAG \
    $DRY_FLAG \
    $EXTRA_FLAGS 2>&1 | sed "s/^/    [path#$IDX] /"
  RC=$?
  set -e

  if [ "$RC" -eq 0 ]; then
    echo "    ✓ path #$IDX sync OK"
  else
    echo "    ✗ path #$IDX sync FAILED (exit=$RC) — sẽ retry lần sau"
  fi
}

run_audit_path() {
  IDX="$1"
  LOCAL_PATH="$(rclone_path_field "$IDX" LOCAL)"
  REMOTE_TARGET="$(rclone_path_field "$IDX" REMOTE)"
  echo "  ── AUDIT path #$IDX  ($LOCAL_PATH ↔ $REMOTE_TARGET)"
  set +e
  rclone --config "$CONFIG_PATH" check "$LOCAL_PATH" "$REMOTE_TARGET" \
    --one-way \
    --log-level NOTICE 2>&1 | sed "s/^/    [check#$IDX] /" | tail -10
  RC=$?
  set -e
  if [ "$RC" -eq 0 ]; then
    echo "    ✓ path #$IDX audit OK (local ⊆ remote)"
  else
    echo "    ⚠ path #$IDX audit khác (exit=$RC) — lần sync sau xử lý"
  fi
}

# Có path nào cần sync không?
HAS_SYNC=0
i=1
while [ "$i" -le "$RCLONE_PATH_COUNT" ]; do
  if rclone_mode_wants "$i" sync; then HAS_SYNC=1; fi
  i=$((i + 1))
done

if [ "$HAS_SYNC" -eq 0 ]; then
  echo ""
  echo "[INFO] Không có path nào có mode bao gồm 'sync'. Sidecar chỉ làm restore nền rồi idle."
  echo "       Giữ container sống (tail -f /dev/null)."
  exec tail -f /dev/null
fi

# ── 2. SYNC LOOP ─────────────────────────────────────────────────
echo ""
echo "── SYNC LOOP (mọi path mode=sync|both) ──────────────────────────"
N=0
while true; do
  N=$((N + 1))
  TS_BEGIN=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  echo ""
  echo "─── SYNC ROUND #$N  @  $TS_BEGIN ──────────────────────────────"

  i=1
  while [ "$i" -le "$RCLONE_PATH_COUNT" ]; do
    if rclone_mode_wants "$i" sync; then
      run_one_sync_path "$i" "$N"
    fi
    i=$((i + 1))
  done

  # Audit định kỳ
  if [ "${AUDIT_EVERY:-0}" -gt 0 ] && [ $((N % AUDIT_EVERY)) -eq 0 ]; then
    echo ""
    echo "─── AUDIT ROUND #$N ───────────────────────────────────────────"
    i=1
    while [ "$i" -le "$RCLONE_PATH_COUNT" ]; do
      if rclone_mode_wants "$i" sync; then
        run_audit_path "$i"
      fi
      i=$((i + 1))
    done
  fi

  sleep "$SYNC_INTERVAL"
done
