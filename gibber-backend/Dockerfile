FROM dart:stable AS backend-build
WORKDIR /app
COPY pubspec.yaml pubspec.lock* ./
RUN dart pub get
COPY lib/ lib/
COPY bin/ bin/
RUN dart build cli -o /app/build

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=backend-build /app/build/bundle/ /app/

RUN ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /app/lib/libsqlite3.so || true && \
    ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /lib/x86_64-linux-gnu/libsqlite3.so.0 || true && \
    ldconfig || true

COPY config/ /app/config/
RUN mkdir -p /app/data /app/web

EXPOSE 8080
CMD ["/app/bin/server", "--host", "0.0.0.0", "--port", "8080", "--db-path", "/app/data/gibber_backend.db", "--config", "/app/config/prosody.cfg.lua", "--mode", "xmpp", "--web-dir", "/app/web"]