#!/usr/bin/env bash
# ================================================================
#  ci-build.sh — CI helper: build 1 lần + deploy
#
#  - Đọc cấu hình compose đã resolve (theo đúng profiles đang bật).
#  - Build MỌI service có "build:" bằng BuildKit cache (gha hoặc local),
#    --load vào docker với ĐÚNG tag mà compose mong đợi (kể cả service
#    không khai báo image:, ví dụ webssh → <project>-webssh).
#  - Sau đó deploy bằng `dc.sh up --no-build` (không build lại lần 2).
#  - Tuỳ chọn: save/load image công khai (non-build) để cache trên runner.
#
#  Env:
#    CACHE_TYPE       = gha | local        (mặc định: gha)
#    LOCAL_CACHE_DIR  = thư mục cache khi type=local (mặc định: $HOME/.buildx-cache)
#    IMAGE_TAR        = đường dẫn tarball để save/load image công khai (tuỳ chọn)
#    COMPOSE_CMD      = lệnh gọi wrapper compose (mặc định: bash docker-compose/scripts/dc.sh)
# ================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

DC="${COMPOSE_CMD:-bash docker-compose/scripts/dc.sh}"
CACHE_TYPE="${CACHE_TYPE:-gha}"
LOCAL_CACHE_DIR="${LOCAL_CACHE_DIR:-$HOME/.buildx-cache}"

command -v jq >/dev/null 2>&1 || { echo "❌ Thiếu 'jq' trên runner."; exit 1; }

echo "==> Resolve compose config (CACHE_TYPE=$CACHE_TYPE)"
CONFIG_JSON="$($DC config --format json)"

# ── (1) Nạp image công khai từ cache nếu có ───────────────────
if [ -n "${IMAGE_TAR:-}" ] && [ -f "$IMAGE_TAR" ]; then
  echo "==> Loading cached public images: $IMAGE_TAR"
  docker load -i "$IMAGE_TAR" || true
fi

# ── (2) Lấy DANH SÁCH TÊN service có build: (1 cột → không lỗi TAB) ─
mapfile -t BUILD_SVCS < <(printf '%s' "$CONFIG_JSON" | jq -r '
  .services | to_entries[]
  | select(.value.build != null)
  | .key')

NEW_CACHE_DIR="${LOCAL_CACHE_DIR}-new"
[ "$CACHE_TYPE" = "local" ] && mkdir -p "$LOCAL_CACHE_DIR" "$NEW_CACHE_DIR"

# Hàm đọc 1 field từ JSON theo service
cfg() { printf '%s' "$CONFIG_JSON" | jq -r --arg s "$1" "$2"; }

for svc in "${BUILD_SVCS[@]:-}"; do
  [ -z "$svc" ] && continue

  # Lấy ĐÚNG tag compose sẽ dùng (kể cả default <project>-<service>)
  image="$($DC config --images "$svc" 2>/dev/null | head -n1 || true)"
  if [ -z "$image" ]; then
    image="${PROJECT_NAME:-myapp}-${svc}"   # fallback an toàn
  fi

  ctx="$(cfg "$svc" '.services[$s].build.context // "."')"
  dockerfile="$(cfg "$svc" '.services[$s].build.dockerfile // "Dockerfile"')"
  if [[ "$dockerfile" = /* ]]; then df="$dockerfile"; else df="$ctx/$dockerfile"; fi

  echo "==> Build [$svc] → $image"
  echo "    context=$ctx  dockerfile=$df"

  if [ "$CACHE_TYPE" = "local" ]; then
    docker buildx build \
      --file "$df" --tag "$image" \
      --cache-from "type=local,src=${LOCAL_CACHE_DIR}/${svc}" \
      --cache-to   "type=local,dest=${NEW_CACHE_DIR}/${svc},mode=max" \
      --provenance=false --load "$ctx"
  else
    docker buildx build \
      --file "$df" --tag "$image" \
      --cache-from "type=gha,scope=${svc}" \
      --cache-to   "type=gha,scope=${svc},mode=max" \
      --provenance=false --load "$ctx"
  fi
done

# Xoay vòng local cache (tránh phình to)
if [ "$CACHE_TYPE" = "local" ] && [ -d "$NEW_CACHE_DIR" ]; then
  rm -rf "$LOCAL_CACHE_DIR"
  mv "$NEW_CACHE_DIR" "$LOCAL_CACHE_DIR"
fi

# ── (3) Deploy: mọi service build đã có image → --no-build ────
echo "==> Tất cả service build đã có sẵn image → up --no-build"
$DC up -d --no-build --remove-orphans

# ── (4) Save image công khai cho lần sau (chỉ khi chưa có tar) ─
if [ -n "${IMAGE_TAR:-}" ] && [ ! -f "$IMAGE_TAR" ]; then
  echo "==> Saving public images → $IMAGE_TAR"
  mapfile -t PUB_IMAGES < <(printf '%s' "$CONFIG_JSON" | jq -r '
    .services | to_entries[]
    | select(.value.build == null)
    | .value.image' | grep -v '^$' | sort -u || true)
  if [ "${#PUB_IMAGES[@]:-0}" -gt 0 ]; then
    mkdir -p "$(dirname "$IMAGE_TAR")"
    docker save "${PUB_IMAGES[@]}" -o "$IMAGE_TAR" || true
  fi
fi

echo "✅ ci-build.sh done."