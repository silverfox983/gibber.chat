FROM dart:stable AS build
WORKDIR /app
COPY gibber-backend/pubspec.yaml gibber-backend/pubspec.lock* ./
RUN dart pub get
COPY gibber-backend/lib/ lib/
COPY gibber-backend/bin/ bin/
RUN dart build cli -o /app/build

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 \
    ca-certificates \
    supervisor \
    prosody \
    openssl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/build/bundle/ /app/

RUN ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /app/lib/libsqlite3.so || true && \
    ldconfig || true

COPY gibber-backend/config/prosody.cfg.lua /etc/prosody/prosody.cfg.lua
COPY gibber-backend/config/entrypoint.sh /app/entrypoint.sh

RUN mkdir -p /app/data /var/run/prosody /var/log/supervisor && \
    chmod +x /app/entrypoint.sh && \
    chown -R prosody:prosody /var/run/prosody /var/lib/prosody

EXPOSE 8080 5222 5269 5280 5281

CMD ["/app/entrypoint.sh"]