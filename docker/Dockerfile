FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates cmake ninja-build g++ g++-mingw-w64-x86-64-posix \
    nlohmann-json3-dev && \
    mkdir -p /opt/openinterminal/include && \
    cp -a /usr/include/nlohmann /opt/openinterminal/include/ && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
ENTRYPOINT ["sh", "/workspace/scripts/build-container.sh"]

