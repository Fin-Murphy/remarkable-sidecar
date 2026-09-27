#!/bin/sh
# Cross-compiles a CMake project for the reMarkable 2 inside Docker, with the official SDK.
# Usage: ./build.sh [PROJECT_DIR]   PROJECT_DIR is relative to tablet/ (default: server).
#                                   Output: PROJECT_DIR/build/
# Needs Docker and the SDK installer in $RM2_SDK_DIR (default ~/rm2-sdk).
set -e
cd "$(dirname "$0")"
SDK_DIR=${RM2_SDK_DIR:-$HOME/rm2-sdk}
if ! docker image inspect rm2-sdk:3.28 >/dev/null 2>&1; then
    docker build -t rm2-sdk:3.28 -f docker/Dockerfile "$SDK_DIR"
fi
PROJECT=${1:-server}
# Mount all of tablet/, so every project can include the shared epaper_private.h.
docker run --rm -v "$PWD":/src -w "/src/${PROJECT%/}" rm2-sdk:3.28 sh -c '
    . /opt/codex/rm2/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi &&
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)"'
