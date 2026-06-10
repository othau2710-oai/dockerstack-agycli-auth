#!/bin/sh
# ================================================================
#  rclone restore.sh — Pull remote → local LẦN ĐẦU khi container start
#  (multi-path: lặp qua từng path có MODE bao gồm 'restore')
#
#  Lọc theo gate (3A):
#    --gated-only      → chỉ restore path GATE=true  (rclone-restore container,
#                        block app start cho tới khi xong)
#    --non-gated-only  → chỉ restore path GATE=false (rclone-sync chạy nền,
#                        KHÔNG block app)
#    (không arg)       → restore tất cả path restore-capable
# ================================================================
set -e

# shellcheck source=/scripts/lib.sh
. /scripts/lib.sh

FILTER="${1:-all}"   # all | --gated-only | --non-gated-only

LOG_LEVEL="$(_env_get RCLONE_LOG_LEVEL INFO)"
EXTRA_FLAGS="$(_env_get RCLONE_EXTRA_FLAGS)"
TRANSFERS="$(_env_get RCLONE_TRANSFERS 32)"
CHECKERS="$(_env_get RCLONE_CHECKERS 64)"
PERF_FLAGS="$(_env_get RCLONE_PERF_FLAGS '--fast-list --s3-no-check-bucket --buffer-size 32M --use-mmap')"

START_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

echo "================================================================="
echo " RCLONE-RESTORE  ::  remote → local (one-shot bootstrap)"
echo " Time         : $START_TS"
echo " Config       : $CONFIG_PATH"
echo " Filter       : $FILTER"
echo " Transfers    : $TRANSFERS / Checkers: $CHECKERS"
echo " Perf flags   : $PERF_FLAGS"
echo " Log level    : $LOG_LEVEL"
echo "================================================================="

# ── Sanity ───────────────────────────────────────────────────────
if [ ! -f "$CONFIG_PATH" ]; then
  echo "[FATAL] Không thấy $CONFIG_PATH — rclone-init đã chạy chưa?" >&2
  exit 1
fi

rclone_collect_paths
if [ "${RCLONE_PATH_COUNT:-0}" -eq 0 ]; then
  echo "[FATAL] Không có path nào để restore." >&2
  exit 1
fi
rclone_print_paths

# Path có nên xử lý theo filter gate không?
_path_passes_filter() {
  _gate="$(rclone_path_field "$1" GATE)"
  case "$FILTER" in
    --gated-only)     [ "$_gate" = "true" ] && return 0 ;;
    --non-gated-only) [ "$_gate" != "true" ] && return 0 ;;
    *)                return 0 ;;
  esac
  return 1
}

restore_one() {
  IDX="$1"
  LOCAL_PATH="$(rclone_path_field "$IDX" LOCAL)"
  REMOTE_TARGET="$(rclone_path_field "$IDX" REMOTE)"
  GATE="$(rclone_path_field "$IDX" GATE)"

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo " RESTORE path #$IDX  (gate=$GATE)"
  echo "   Local : $LOCAL_PATH"
  echo "   Remote: $REMOTE_TARGET"
  echo "════════════════════════════════════════════════════════════════"

  mkdir -p "$LOCAL_PATH"

  # ── Snapshot LOCAL trước restore ───────────────────────────────
  LOCAL_BEFORE_FILES=$(find "$LOCAL_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  Local trước : ${LOCAL_BEFORE_FILES:-0} files"

  # ── Probe REMOTE ───────────────────────────────────────────────
  REMOTE_OBJS=0
  if REMOTE_INFO=$(rclone --config "$CONFIG_PATH" size "$REMOTE_TARGET" --json 2>/tmp/rclone-restore.err); then
    REMOTE_OBJS=$(printf '%s' "$REMOTE_INFO" | sed -n 's/.*"count":[[:space:]]*\([0-9-]*\).*/\1/p' | head -1)
    : "${REMOTE_OBJS:=0}"
    echo "  Remote files: $REMOTE_OBJS"
  else
    ERR=$(cat /tmp/rclone-restore.err 2>/dev/null)
    if echo "$ERR" | grep -qiE 'not.*found|does.*not.*exist|404|NoSuchKey|NoSuchBucket'; then
      echo "  Remote files: 0 (remote path chưa tồn tại — fresh start)"
      REMOTE_OBJS=0
    else
      echo "[FATAL] Path #$IDX: không kết nối được remote." >&2
      echo "        $ERR" >&2
      return 1
    fi
  fi

  if [ "${REMOTE_OBJS:-0}" = "0" ]; then
    echo "  → Remote trống, bỏ qua restore (app sẽ tự khởi tạo data)."
    return 0
  fi

  # ── COPY remote → local (additive) ─────────────────────────────
  echo "  → Pulling remote → local …"
  COPY_START=$(date +%s)
  set +e
  rclone --config "$CONFIG_PATH" copy "$REMOTE_TARGET" "$LOCAL_PATH" \
    --log-level "$LOG_LEVEL" \
    --stats 5s \
    --stats-one-line \
    --transfers "$TRANSFERS" \
    --checkers "$CHECKERS" \
    --create-empty-src-dirs \
    $PERF_FLAGS \
    $EXTRA_FLAGS
  RC=$?
  set -e
  COPY_SEC=$(( $(date +%s) - COPY_START ))

  if [ "$RC" -ne 0 ]; then
    echo "[FATAL] Path #$IDX: rclone copy thất bại (exit=$RC)." >&2
    return "$RC"
  fi

  LOCAL_AFTER_FILES=$(find "$LOCAL_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "  ✓ Restore #$IDX OK trong ${COPY_SEC}s — local: ${LOCAL_AFTER_FILES:-0} files (remote: ${REMOTE_OBJS})"
  if [ "${LOCAL_AFTER_FILES:-0}" -lt "${REMOTE_OBJS:-0}" ]; then
    echo "  [WARN] Local files ít hơn remote — kiểm tra exclude pattern."
  fi
  return 0
}

# ── Loop qua các path ────────────────────────────────────────────
PROCESSED=0
i=1
while [ "$i" -le "$RCLONE_PATH_COUNT" ]; do
  if rclone_mode_wants "$i" restore && _path_passes_filter "$i"; then
    restore_one "$i" || {
      echo "[FATAL] Restore path #$i thất bại → exit để app KHÔNG start với data thiếu." >&2
      exit 1
    }
    PROCESSED=$((PROCESSED + 1))
  fi
  i=$((i + 1))
done

echo ""
if [ "$PROCESSED" -eq 0 ]; then
  echo "[INFO] Không có path nào khớp filter '$FILTER' + mode restore — không làm gì."
fi
echo "[DONE] rclone-restore ($FILTER) completed at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================="
exit 0
