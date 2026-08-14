FROM debian:bookworm-slim AS certgen
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /certs && \
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -keyout /certs/gibber.chat.key \
        -out /certs/gibber.chat.crt \
        -subj "/CN=gibber.chat/O=Gibber/C=US"

FROM prosody/prosody:latest
COPY --from=certgen /certs/gibber.chat.key /etc/prosody/certs/gibber.chat.key
COPY --from=certgen /certs/gibber.chat.crt /etc/prosody/certs/gibber.chat.crt
RUN chown -R prosody:prosody /etc/prosody/certs