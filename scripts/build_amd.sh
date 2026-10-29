#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

for tool in hipify-perl hipcc make; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Required ROCm build tool not found: %s\n' "$tool" >&2
        exit 1
    fi
done

if [[ -z "${ROCM_ARCH:-}" ]]; then
    if ! command -v amdgpu-arch >/dev/null 2>&1; then
        printf 'Set ROCM_ARCH (for example gfx1151) or install amdgpu-arch.\n' >&2
        exit 1
    fi
    ROCM_ARCH=$(amdgpu-arch | head -n 1)
fi

if [[ -z "$ROCM_ARCH" ]]; then
    printf 'Unable to detect a ROCm GPU architecture; set ROCM_ARCH explicitly.\n' >&2
    exit 1
fi

if [[ -n "${DARKNET_ROCM_BUILD_DIR:-}" ]]; then
    BUILD_DIR=$(mkdir -p "$DARKNET_ROCM_BUILD_DIR" && cd "$DARKNET_ROCM_BUILD_DIR" && pwd)
    if [[ "$BUILD_DIR" == "$ROOT" || "$BUILD_DIR" == "$ROOT/"* ]]; then
        printf 'DARKNET_ROCM_BUILD_DIR must be outside the source tree.\n' >&2
        exit 1
    fi
    if [[ -n "$(find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        printf 'Build directory is not empty: %s\n' "$BUILD_DIR" >&2
        exit 1
    fi
else
    BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/darknet-rocm.XXXXXX")
fi

mkdir -p "$BUILD_DIR"
for path in Makefile src include 3rdparty scripts; do
    cp -a "$ROOT/$path" "$BUILD_DIR/"
done
cp -a "$ROOT"/*.sh "$BUILD_DIR/"
ln -s "$ROOT/cfg" "$BUILD_DIR/cfg"
ln -s "$ROOT/data" "$BUILD_DIR/data"

for source in "$BUILD_DIR"/src/*.cu "$BUILD_DIR"/src/*.c "$BUILD_DIR"/src/*.h; do
    hipify-perl -inplace "$source"
done
hipify-perl -inplace "$BUILD_DIR/include/darknet.h"

# Keep Darknet's 32-bit packed-binary kernel launch syntax accepted by hipcc.
find "$BUILD_DIR/src" -type f \( -name '*.cu' -o -name '*.c' -o -name '*.h' \) \
    -exec sed -i -e 's/<< </<<</g' -e 's/>> >/>>>/g' {} +

printf 'Building Darknet for %s in %s\n' "$ROCM_ARCH" "$BUILD_DIR"
make -C "$BUILD_DIR" "$@" USE_ROCM=1 GPU=1 ROCM_ARCH="$ROCM_ARCH" \
    USE_CPP=1 CUDNN=0 CUDNN_HALF=0
printf 'Darknet ROCm build complete: %s/darknet\n' "$BUILD_DIR"
