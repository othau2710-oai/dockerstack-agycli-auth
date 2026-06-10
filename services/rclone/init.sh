#!/bin/sh
# ================================================================
#  rclone init.sh — Decode RCLONE_CONFIG_BASE64 → rclone.conf
#
#  Trách nhiệm:
#    1. Đọc RCLONE_CONFIG_BASE64 từ env
#    2. Decode về /config/rclone/rclone.conf
#    3. Validate config bằng `rclone config dump`
#    4. Validate MỌI remote dùng trong các path (multi-path) có trong config
#    5. In ra danh sách remotes phát hiện được + bảng path
#
#  Service này chạy ONE-SHOT, exit 0 khi xong, exit 1 nếu lỗi.
#  Tất cả service rclone khác depends_on service này.
# ================================================================
set -e

# shellcheck source=/scripts/lib.sh
. /scripts/lib.sh

CONFIG_B64="$(_env_get RCLONE_CONFIG_BASE64)"
CONFIG_DIR=$(dirname "$CONFIG_PATH")

echo "================================================================="
echo " RCLONE-INIT  ::  Build rclone.conf from RCLONE_CONFIG_BASE64"
echo " Time         : $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo " Config path  : $CONFIG_PATH"
echo "================================================================="

# ── 1. Validate biến môi trường ──────────────────────────────────
if [ -z "$CONFIG_B64" ]; then
  echo "[FATAL] RCLONE_CONFIG_BASE64 chưa được set trong .env." >&2
  echo "        Cách tạo:" >&2
  echo "          base64 -w 0 services/rclone/rclone.conf > /tmp/b64.txt" >&2
  echo "          → copy nội dung file vào RCLONE_CONFIG_BASE64 trong .env" >&2
  exit 1
fi

# ── 2. Decode & ghi file ─────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

# Bóc bỏ khoảng trắng / xuống dòng (nhiều editor thêm vào khi paste).
CLEAN_B64=$(printf '%s' "$CONFIG_B64" | tr -d ' \t\r\n')

if ! printf '%s' "$CLEAN_B64" | base64 -d > "$CONFIG_PATH" 2>/tmp/rclone-init.err; then
  echo "[FATAL] Decode RCLONE_CONFIG_BASE64 thất bại." >&2
  echo "        Lỗi: $(cat /tmp/rclone-init.err 2>/dev/null)" >&2
  echo "        Kiểm tra lại giá trị base64 trong .env (không có ký tự lạ)." >&2
  exit 1
fi

chmod 600 "$CONFIG_PATH" 2>/dev/null || true

CONFIG_SIZE=$(wc -c < "$CONFIG_PATH" | tr -d ' ')
CONFIG_LINES=$(wc -l < "$CONFIG_PATH" | tr -d ' ')

echo "[OK] Wrote rclone.conf"
echo "     Size  : ${CONFIG_SIZE} bytes"
echo "     Lines : ${CONFIG_LINES}"

# ── 3. Validate bằng `rclone config dump` ────────────────────────
echo ""
echo "── Validating config ────────────────────────────────────────────"
if ! rclone --config "$CONFIG_PATH" config dump > /tmp/rclone-dump.json 2>/tmp/rclone-init.err; then
  echo "[FATAL] rclone không parse được config." >&2
  echo "        Lỗi: $(cat /tmp/rclone-init.err 2>/dev/null)" >&2
  exit 1
fi

# ── 4. List remotes phát hiện được ───────────────────────────────
echo ""
echo "── Remotes detected ─────────────────────────────────────────────"
REMOTES=$(rclone --config "$CONFIG_PATH" listremotes 2>/dev/null || true)
if [ -z "$REMOTES" ]; then
  echo "[FATAL] Không tìm thấy remote nào trong config." >&2
  echo "        Mỗi remote phải có một section [name] trong rclone.conf." >&2
  exit 1
fi

echo "$REMOTES" | while IFS= read -r r; do
  [ -z "$r" ] && continue
  TYPE=$(rclone --config "$CONFIG_PATH" config show "${r%:}" 2>/dev/null \
          | awk -F= '/^type/{gsub(/ /,"",$2); print $2; exit}')
  printf "  • %-20s  type=%s\n" "$r" "${TYPE:-?}"
done

# ── 5. Thu thập & validate các path (multi-path) ─────────────────
echo ""
echo "── Paths configured ─────────────────────────────────────────────"
rclone_collect_paths

if [ "${RCLONE_PATH_COUNT:-0}" -eq 0 ]; then
  echo "[FATAL] Không có path nào được cấu hình." >&2
  echo "        Khai báo RCLONE_PATH_1_LOCAL/REMOTE/MODE/GATE trong .env," >&2
  echo "        hoặc đặt RCLONE_REMOTE_TARGET (+ RCLONE_LOCAL_PATH) cho chế độ 1-path." >&2
  exit 1
fi

rclone_print_paths

# Validate mỗi remote của từng path tồn tại trong config.
echo ""
echo "── Validating each path's remote ────────────────────────────────"
i=1
while [ "$i" -le "$RCLONE_PATH_COUNT" ]; do
  REMOTE_TARGET="$(rclone_path_field "$i" REMOTE)"
  REMOTE_NAME="${REMOTE_TARGET%%:*}"

  if [ -z "$REMOTE_NAME" ] || [ "$REMOTE_NAME" = "$REMOTE_TARGET" ]; then
    echo "[FATAL] Path #$i: REMOTE sai format: '$REMOTE_TARGET'" >&2
    echo "        Format đúng: <tên_remote_trong_rclone.conf>:<bucket_hoặc_path>" >&2
    exit 1
  fi

  if ! printf '%s\n' "$REMOTES" | grep -Fxq "${REMOTE_NAME}:"; then
    echo "[FATAL] Path #$i: remote '${REMOTE_NAME}:' không có trong config." >&2
    echo "        Remote phát hiện được:" >&2
    printf '          %s\n' $REMOTES >&2
    exit 1
  fi

  echo "  [OK] Path #$i → remote '${REMOTE_NAME}:' khớp config."
  i=$((i + 1))
done

echo ""
echo "[DONE] rclone-init completed at $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================="
exit 0
