#!/bin/sh
# ================================================================
#  rclone lib.sh — Shared helpers cho init/restore/sync
#
#  Hỗ trợ CẤU HÌNH NHIỀU PATH qua indexed env vars (1A):
#
#    RCLONE_PATH_1_LOCAL=/data/app
#    RCLONE_PATH_1_REMOTE=remote_store:bucket/app
#    RCLONE_PATH_1_MODE=both          # restore | sync | both
#    RCLONE_PATH_1_GATE=true          # true → app chờ restore path này xong
#
#    RCLONE_PATH_2_LOCAL=/data/cache
#    RCLONE_PATH_2_REMOTE=remote_store:bucket/cache
#    RCLONE_PATH_2_MODE=sync
#    RCLONE_PATH_2_GATE=false
#    ...
#
#  Các biến này được compose forward vào container dưới prefix STACK_
#  (STACK_RCLONE_PATH_1_LOCAL, ...) để tránh rclone tự map RCLONE_* thành
#  CLI flags. lib.sh đọc cả 2 dạng (STACK_ ưu tiên).
#
#  FALLBACK 1-PATH (tương thích .env cũ):
#    Nếu KHÔNG khai báo path nào theo index, nhưng có RCLONE_REMOTE_TARGET,
#    lib.sh tự tạo 1 path:
#        LOCAL  = RCLONE_LOCAL_PATH (mặc định /data)
#        REMOTE = RCLONE_REMOTE_TARGET
#        MODE   = both
#        GATE   = true
#    → stack chạy y như hành vi cũ, không phá vỡ deployment hiện tại.
#
#  API (gọi từ init/restore/sync):
#    rclone_collect_paths     → set RCLONE_PATH_COUNT + biến _PATH_i_*
#    rclone_path_field i NAME → in giá trị field (LOCAL/REMOTE/MODE/GATE)
#    rclone_mode_wants i WHAT → return 0 nếu mode path i bao gồm WHAT
#                               (WHAT = restore | sync)
# ================================================================

# Số path tối đa quét (giới hạn an toàn, khớp với compose enumerate).
RCLONE_MAX_PATHS="${RCLONE_MAX_PATHS:-10}"

CONFIG_PATH="${STACK_RCLONE_CONFIG_PATH:-${RCLONE_CONFIG_PATH:-/config/rclone/rclone.conf}}"

# Đọc env theo cả 2 prefix: STACK_<NAME> ưu tiên, fallback <NAME>.
_env_get() {
  # $1 = tên biến (không prefix), $2 = default
  _name="$1"
  _def="${2:-}"
  eval "_v=\${STACK_${_name}:-\${${_name}:-}}"
  if [ -z "$_v" ]; then
    printf '%s' "$_def"
  else
    printf '%s' "$_v"
  fi
}

# Internal: lưu trữ field của từng path vào biến _RCLONE_PATH_<i>_<FIELD>.
_set_path_field() {
  # $1=index $2=field $3=value
  eval "_RCLONE_PATH_$1_$2=\$3"
}

rclone_path_field() {
  # $1=index $2=field → in value
  eval "printf '%s' \"\${_RCLONE_PATH_$1_$2:-}\""
}

# Trả về 0 nếu mode của path $1 bao gồm thao tác $2 (restore|sync).
rclone_mode_wants() {
  _idx="$1"
  _what="$2"
  _mode="$(rclone_path_field "$_idx" MODE)"
  [ -z "$_mode" ] && _mode="both"
  case "$_mode" in
    both) return 0 ;;
    restore) [ "$_what" = "restore" ] && return 0 ;;
    sync) [ "$_what" = "sync" ] && return 0 ;;
  esac
  return 1
}

# Quét indexed vars → điền RCLONE_PATH_COUNT + các _RCLONE_PATH_i_*.
rclone_collect_paths() {
  RCLONE_PATH_COUNT=0
  _i=1
  while [ "$_i" -le "$RCLONE_MAX_PATHS" ]; do
    _local="$(_env_get "RCLONE_PATH_${_i}_LOCAL")"
    _remote="$(_env_get "RCLONE_PATH_${_i}_REMOTE")"

    # Một path hợp lệ cần CẢ local + remote. Index trống → dừng quét tiếp
    # CHỈ KHI cũng không có index nào phía sau (cho phép "lỗ hổng" index thì
    # vẫn quét hết tới MAX để tránh bỏ sót do người dùng đánh số không liền).
    if [ -n "$_local" ] && [ -n "$_remote" ]; then
      _mode="$(_env_get "RCLONE_PATH_${_i}_MODE" both)"
      _gate="$(_env_get "RCLONE_PATH_${_i}_GATE" false)"

      # Chuẩn hoá chữ thường.
      _mode="$(printf '%s' "$_mode" | tr '[:upper:]' '[:lower:]')"
      _gate="$(printf '%s' "$_gate" | tr '[:upper:]' '[:lower:]')"

      case "$_mode" in
        restore|sync|both) : ;;
        *)
          echo "[WARN] RCLONE_PATH_${_i}_MODE='$_mode' không hợp lệ → dùng 'both'." >&2
          _mode="both"
          ;;
      esac

      RCLONE_PATH_COUNT=$((RCLONE_PATH_COUNT + 1))
      _set_path_field "$RCLONE_PATH_COUNT" LOCAL  "$_local"
      _set_path_field "$RCLONE_PATH_COUNT" REMOTE "$_remote"
      _set_path_field "$RCLONE_PATH_COUNT" MODE   "$_mode"
      _set_path_field "$RCLONE_PATH_COUNT" GATE   "$_gate"
    fi
    _i=$((_i + 1))
  done

  # ── Fallback 1-path (tương thích .env cũ) ──────────────────────
  if [ "$RCLONE_PATH_COUNT" -eq 0 ]; then
    _remote="$(_env_get RCLONE_REMOTE_TARGET)"
    if [ -n "$_remote" ]; then
      _local="$(_env_get RCLONE_LOCAL_PATH /data)"
      RCLONE_PATH_COUNT=1
      _set_path_field 1 LOCAL  "$_local"
      _set_path_field 1 REMOTE "$_remote"
      _set_path_field 1 MODE   both
      _set_path_field 1 GATE   true
      echo "[INFO] Không có RCLONE_PATH_N_* → fallback 1 path từ RCLONE_REMOTE_TARGET (mode=both, gate=true)."
    fi
  fi

  export RCLONE_PATH_COUNT
}

# In bảng tóm tắt các path đã thu thập (dùng cho banner).
rclone_print_paths() {
  echo "  Paths        : $RCLONE_PATH_COUNT"
  _j=1
  while [ "$_j" -le "$RCLONE_PATH_COUNT" ]; do
    printf "    [%d] %s  ←→  %s  (mode=%s gate=%s)\n" \
      "$_j" \
      "$(rclone_path_field "$_j" LOCAL)" \
      "$(rclone_path_field "$_j" REMOTE)" \
      "$(rclone_path_field "$_j" MODE)" \
      "$(rclone_path_field "$_j" GATE)"
    _j=$((_j + 1))
  done
}
