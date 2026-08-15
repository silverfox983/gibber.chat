FROM debian:bookworm-slim AS certgen
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /certs && \
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -keyout /certs/gibberapp.online.key \
        -out /certs/gibberapp.online.crt \
        -subj "/CN=gibberapp.online/O=Gibber/C=US"

FROM prosody/prosody:latest
RUN apt-get update && apt-get install -y --no-install-recommends prosody-modules && rm -rf /var/lib/apt/lists/*
COPY --from=certgen /certs/gibberapp.online.key /etc/prosody/certs/gibberapp.online.key
COPY --from=certgen /certs/gibberapp.online.crt /etc/prosody/certs/gibberapp.online.crt
RUN chown -R prosody:prosody /etc/prosody/certs