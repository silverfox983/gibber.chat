FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock* ./
RUN dart pub get
COPY lib/ lib/
COPY bin/ bin/
RUN dart build cli -o /app/build

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    lsb-release \
    && curl -fsSL -o /etc/apt/sources.list.d/prosody.sources https://prosody.im/downloads/repos/$(lsb_release -sc)/prosody.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    libsqlite3-0 \
    ca-certificates \
    supervisor \
    prosody-13.0 \
    janus \
    coturn \
    openssl \
    curl \
    socat \
    git \
    cron \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/acmesh-official/acme.sh.git /opt/acme.sh \
    && cd /opt/acme.sh \
    && ./acme.sh --install \
    && rm -rf /opt/acme.sh

COPY --from=build /app/build/bundle/ /app/

RUN ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /app/lib/libsqlite3.so || true && \
    ldconfig || true

COPY config/prosody.cfg.lua /etc/prosody/prosody.cfg.lua
COPY config/janus/ /etc/janus/
COPY config/turnserver.conf /etc/coturn/turnserver.conf
COPY config/entrypoint.sh /app/entrypoint.sh

RUN mkdir -p /app/data /var/run/prosody /var/run/coturn /etc/default && \
    echo 'TURNSERVER_ENABLED=1' > /etc/default/coturn && \
    chmod +x /app/entrypoint.sh && \
    chown -R prosody:prosody /var/run/prosody /var/lib/prosody

EXPOSE 8080 5222 5269 5280 5281 8188 8088 3478 3478/udp 5349 5349/udp 49152-49200/udp 10000-10020/udp

CMD ["/app/entrypoint.sh"]