#!/bin/sh
# Cross-compiles a CMake project for the reMarkable 2 inside Docker, with the official SDK.
# Usage: ./build.sh [PROJECT_DIR]   PROJECT_DIR is relative to tablet/ (default: server).
#                                   Output: PROJECT_DIR/build/
# Settings (SDK location and file) come from ../config.local; see ../config.example.
set -e
cd "$(dirname "$0")"
[ -f ../config.local ] && . ../config.local
case "$(uname -m)" in arm64|aarch64) ARCH=aarch64 ;; *) ARCH=x86_64 ;; esac
SDK_DIR=${RM2_SDK_DIR:-$HOME/rm2-sdk}
SDK_FILE=${RM2_SDK_FILE:-remarkable-production-image-5.8.203-rm2-public-$ARCH-toolchain.sh}
if [ ! -f "$SDK_DIR/$SDK_FILE" ]; then
    echo "SDK installer not found: $SDK_DIR/$SDK_FILE"
    echo "Download it from https://developer.remarkable.com/links, or set RM2_SDK_DIR / RM2_SDK_FILE in config.local."
    exit 1
fi
# One image per SDK installer, so switching SDKs never reuses the wrong one.
IMAGE=rm2-sdk:$(basename "$SDK_FILE" .sh)
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -t "$IMAGE" --build-arg SDK="$SDK_FILE" -f docker/Dockerfile "$SDK_DIR"
fi
PROJECT=${1:-server}
# Mount all of tablet/, so every project can include the shared epaper_private.h.
docker run --rm -v "$PWD":/src -w "/src/${PROJECT%/}" "$IMAGE" sh -c '
    . /opt/codex/rm2/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi &&
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)"'
