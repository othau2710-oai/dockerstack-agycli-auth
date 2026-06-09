#!/bin/sh
# ================================================================
#  rclone restore.sh — Đồng bộ remote → local LẦN ĐẦU khi container start
#  (đã tối ưu tốc độ: tăng transfers/checkers + flag S3 song song)
# ================================================================
set -e

CONFIG_PATH="${STACK_RCLONE_CONFIG_PATH:-${RCLONE_CONFIG_PATH:-/config/rclone/rclone.conf}}"
LOCAL_PATH="${STACK_RCLONE_LOCAL_PATH:-${RCLONE_LOCAL_PATH:-/data}}"
REMOTE_TARGET="${STACK_RCLONE_REMOTE_TARGET:-${RCLONE_REMOTE_TARGET:-}}"
LOG_LEVEL="${STACK_RCLONE_LOG_LEVEL:-${RCLONE_LOG_LEVEL:-INFO}}"
EXTRA_FLAGS="${STACK_RCLONE_EXTRA_FLAGS:-${RCLONE_EXTRA_FLAGS:-}}"

# ⬆️ Nâng mặc định: 8→32 transfers, 16→64 checkers (che latency S3 file nhỏ)
TRANSFERS="${STACK_RCLONE_TRANSFERS:-${RCLONE_TRANSFERS:-32}}"
CHECKERS="${STACK_RCLONE_CHECKERS:-${RCLONE_CHECKERS:-64}}"

# 🆕 Bộ flag tăng tốc mặc định cho S3 nhiều file nhỏ.
#    Override hoàn toàn bằng RCLONE_PERF_FLAGS, hoặc nối thêm bằng RCLONE_EXTRA_FLAGS.
PERF_FLAGS="${STACK_RCLONE_PERF_FLAGS:-${RCLONE_PERF_FLAGS:---fast-list --s3-no-check-bucket --buffer-size 32M --use-mmap}}"

START_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

echo "================================================================="
echo " RCLONE-RESTORE  ::  remote → local (one-shot bootstrap)"
echo " Time         : $START_TS"
echo " Config       : $CONFIG_PATH"
echo " Local path   : $LOCAL_PATH"
echo " Remote target: $REMOTE_TARGET"
echo " Transfers    : $TRANSFERS / Checkers: $CHECKERS"
echo " Perf flags   : $PERF_FLAGS"
echo " Log level    : $LOG_LEVEL"
echo "================================================================="

# ── 1. Sanity checks ─────────────────────────────────────────────
if [ -z "$REMOTE_TARGET" ]; then
  echo "[FATAL] RCLONE_REMOTE_TARGET chưa set trong .env." >&2
  exit 1
fi
if [ ! -f "$CONFIG_PATH" ]; then
  echo "[FATAL] Không thấy $CONFIG_PATH — rclone-init đã chạy chưa?" >&2
  exit 1
fi

mkdir -p "$LOCAL_PATH"

# ── 2. Snapshot LOCAL trước khi restore ──────────────────────────
echo ""
echo "── BEFORE  ::  Local state (trước khi pull) ────────────────────"
LOCAL_BEFORE_SIZE=$(du -sb "$LOCAL_PATH" 2>/dev/null | awk '{print $1}')
LOCAL_BEFORE_FILES=$(find "$LOCAL_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  Local size   : ${LOCAL_BEFORE_SIZE:-0} bytes"
echo "  Local files  : ${LOCAL_BEFORE_FILES:-0}"
if [ "${LOCAL_BEFORE_FILES:-0}" -gt 0 ] && [ "${LOCAL_BEFORE_FILES:-0}" -lt 50 ]; then
  echo "  Local listing:"
  find "$LOCAL_PATH" -type f -printf "    %p (%s bytes)\n" 2>/dev/null | head -50 || \
    find "$LOCAL_PATH" -type f 2>/dev/null | head -50 | while read -r f; do
      sz=$(stat -c '%s' "$f" 2>/dev/null || echo "?")
      echo "    $f ($sz bytes)"
    done
fi

# ── 3. Snapshot REMOTE ───────────────────────────────────────────
echo ""
echo "── REMOTE  ::  Probe remote state ──────────────────────────────"
echo "  Probing: rclone size '$REMOTE_TARGET' …"

REMOTE_INFO=""
REMOTE_BYTES=0
REMOTE_OBJS=0
if REMOTE_INFO=$(rclone --config "$CONFIG_PATH" size "$REMOTE_TARGET" \
                   --json 2>/tmp/rclone-restore.err); then
  REMOTE_BYTES=$(printf '%s' "$REMOTE_INFO" | sed -n 's/.*"bytes":[[:space:]]*\([0-9-]*\).*/\1/p' | head -1)
  REMOTE_OBJS=$(printf '%s' "$REMOTE_INFO" | sed -n 's/.*"count":[[:space:]]*\([0-9-]*\).*/\1/p' | head -1)
  : "${REMOTE_BYTES:=0}"
  : "${REMOTE_OBJS:=0}"
  echo "  Remote bytes : $REMOTE_BYTES"
  echo "  Remote files : $REMOTE_OBJS"
else
  ERR=$(cat /tmp/rclone-restore.err 2>/dev/null)
  if echo "$ERR" | grep -qiE 'not.*found|does.*not.*exist|404|NoSuchKey|NoSuchBucket'; then
    echo "  Remote bytes : 0 (remote path chưa tồn tại — sẽ tạo khi sync)"
    echo "  Remote files : 0"
    REMOTE_BYTES=0
    REMOTE_OBJS=0
  else
    echo "[FATAL] Không kết nối được remote." >&2
    echo "        $ERR" >&2
    exit 1
  fi
fi

# ── 4. Quyết định: fresh hay restore ─────────────────────────────
echo ""
if [ "${REMOTE_OBJS:-0}" = "0" ]; then
  echo "── DECISION  ::  Remote trống → FRESH START ────────────────────"
  echo "  Bỏ qua restore. App sẽ tự khởi tạo data lần đầu."
  echo "  Sidecar rclone-sync sẽ tự push lên remote khi có data."
  echo ""
  echo "[DONE] rclone-restore (fresh) at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "================================================================="
  exit 0
fi

echo "── DECISION  ::  Remote có data → RESTORE remote → local ───────"
echo "  Mode: rclone copy (additive, không xóa file local)"
echo ""

# ── 5. Liệt kê file remote (để log) — thêm --fast-list cho nhanh ──
echo "── REMOTE LIST  (top 100, sorted by modtime desc) ──────────────"
rclone --config "$CONFIG_PATH" lsl "$REMOTE_TARGET" --fast-list 2>/dev/null \
  | sort -k2 -r | head -100 \
  | awk '{printf "  %-12s  %s  %s\n", $1, $2"T"$3, substr($0, index($0,$4))}' \
  || echo "  (could not list)"

# ── 6. Thực hiện copy với --stats + flag tăng tốc ─────────────────
echo ""
echo "── COPY  ::  Pulling remote → local ────────────────────────────"
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
COPY_END=$(date +%s)
COPY_SEC=$((COPY_END - COPY_START))

if [ "$RC" -ne 0 ]; then
  echo "[FATAL] rclone copy thất bại (exit=$RC). Container sẽ exit để app KHÔNG start với data thiếu." >&2
  echo "        Tham khảo log phía trên để xác định nguyên nhân." >&2
  exit "$RC"
fi

# ── 7. Verify post-copy ──────────────────────────────────────────
echo ""
echo "── VERIFY  ::  So sánh local vs remote sau khi copy ────────────"
LOCAL_AFTER_SIZE=$(du -sb "$LOCAL_PATH" 2>/dev/null | awk '{print $1}')
LOCAL_AFTER_FILES=$(find "$LOCAL_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  Local size   : ${LOCAL_AFTER_SIZE:-0} bytes  (was ${LOCAL_BEFORE_SIZE:-0})"
echo "  Local files  : ${LOCAL_AFTER_FILES:-0}  (was ${LOCAL_BEFORE_FILES:-0})"
echo "  Remote files : ${REMOTE_OBJS}"
echo "  Duration     : ${COPY_SEC}s"

if [ "${LOCAL_AFTER_FILES:-0}" -lt "${REMOTE_OBJS:-0}" ]; then
  echo "  [WARN] Local files ít hơn remote files — kiểm tra exclude pattern."
fi

echo ""
echo "── LOCAL LIST AFTER  (top 30) ──────────────────────────────────"
find "$LOCAL_PATH" -type f -printf "  %T@  %s  %p\n" 2>/dev/null \
  | sort -nr | head -30 \
  | awk '{ts=strftime("%Y-%m-%d %H:%M:%S", $1); printf "  %s  %10d  %s\n", ts, $2, $3}' \
  || find "$LOCAL_PATH" -type f 2>/dev/null | head -30

echo ""
echo "[DONE] rclone-restore completed at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================="
exit 0