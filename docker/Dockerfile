FROM swift:6.3-noble AS builder

WORKDIR /build

COPY Package.swift Package.resolved ./
RUN swift package resolve

RUN apt-get update && apt-get install -y build-essential wget && \
    cd /tmp && \
    wget -q https://www.sqlite.org/2025/sqlite-autoconf-3510000.tar.gz && \
    tar xzf sqlite-autoconf-3510000.tar.gz && \
    cd sqlite-autoconf-3510000 && \
    CPPFLAGS="-DSQLITE_ENABLE_SNAPSHOT" ./configure --prefix=/usr && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    rm -rf /tmp/sqlite-autoconf-3510000* && \
    rm -rf /var/lib/apt/lists/*

COPY Sources/ ./Sources/
RUN sed -i '/platforms:/,/],/{/platforms:/d;/\.macOS.*$/d;/],$/d}' Package.swift && \
    sed -i '/\.testTarget/,/),/{/\.testTarget/,/)/d}' Package.swift && \
    swift build --configuration release && \
    strip .build/release/cli .build/release/mcp-stdio .build/release/mcp-server .build/release/websocket-observer

FROM swift:6.3-noble-slim AS runtime

WORKDIR /app

COPY --from=builder /build/.build/release/cli                  ./cli
COPY --from=builder /build/.build/release/mcp-stdio            ./mcp-stdio
COPY --from=builder /build/.build/release/mcp-server           ./mcp-server
COPY --from=builder /build/.build/release/websocket-observer   ./websocket-observer

COPY --from=builder /usr/lib/aarch64-linux-gnu/libsqlite3.so.0 /usr/lib/aarch64-linux-gnu/
COPY --from=builder /usr/lib/aarch64-linux-gnu/libsqlite3.so.0 /usr/local/lib/
RUN ln -sf /usr/lib/aarch64-linux-gnu/libsqlite3.so.0 /usr/lib/aarch64-linux-gnu/libsqlite3.so && \
    ln -sf /usr/local/lib/libsqlite3.so.0 /usr/local/lib/libsqlite3.so && \
    mkdir -p /etc/ld.so.conf.d && echo '/usr/local/lib' > /etc/ld.so.conf.d/sqlite.conf && \
    ldconfig

EXPOSE 3000 8080

VOLUME ["/data"]

CMD ["websocket-observer", "--observe", "--http-host", "0.0.0.0:8080", "--db", "/data"]
