# Linux build environment with the reMarkable 2 SDK (default: OS 3.28.0.172).
# Build context: the directory holding the SDK installer. build.sh passes its file name as SDK.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 xz-utils file make && rm -rf /var/lib/apt/lists/*
ARG SDK=remarkable-production-image-5.8.203-rm2-public-aarch64-toolchain.sh
COPY ${SDK} /tmp/sdk.sh
RUN sh /tmp/sdk.sh -y -d /opt/codex/rm2 && rm /tmp/sdk.sh
WORKDIR /src
