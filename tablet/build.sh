#!/bin/sh
# Cross-compiles a CMake project for the reMarkable 2 inside Docker.
# Usage: ./build.sh PROJECT_DIR      (output: PROJECT_DIR/build/)
# Needs Docker and the SDK installer in $RM2_SDK_DIR (default ~/rm2-sdk).
set -e
cd "$(dirname "$0")"
SDK_DIR=${RM2_SDK_DIR:-$HOME/rm2-sdk}
if ! docker image inspect rm2-sdk:3.28 >/dev/null 2>&1; then
    docker build -t rm2-sdk:3.28 -f Dockerfile "$SDK_DIR"
fi
PROJECT=$(cd "$1" && pwd)
# Mount the parent too, so projects can share headers one level up (../epaper_private.h).
docker run --rm -v "$(dirname "$PROJECT")":/src -w "/src/$(basename "$PROJECT")" rm2-sdk:3.28 sh -c '
    . /opt/codex/rm2/environment-setup-cortexa7hf-neon-remarkable-linux-gnueabi &&
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j"$(nproc)"'
