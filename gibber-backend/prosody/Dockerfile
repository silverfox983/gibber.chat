FROM debian:bookworm-slim AS certgen
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
# A real local CA + a server cert signed by it: a self-signed LEAF cannot be a
# trusted anchor, but gateway components (slidge) load the CA root via
# SSL_CERT_FILE so prosody's TLS file-share endpoint verifies cleanly.
RUN mkdir -p /certs && \
    openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
      -keyout /certs/gibber-ca.key -out /certs/gibber-ca.crt \
      -subj "/CN=Gibber Local CA/O=Gibber/C=US" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" && \
    openssl req -new -newkey rsa:2048 -nodes \
      -keyout /certs/gibberapp.online.key -out /certs/gibberapp.online.csr \
      -subj "/CN=gibberapp.online/O=Gibber/C=US" && \
    printf "subjectAltName=DNS:gibberapp.online,DNS:*.gibberapp.online,DNS:conference.gibberapp.online,DNS:pubsub.gibberapp.online,DNS:spaces.gibberapp.online,DNS:whatsapp.gibberapp.online,DNS:telegram.gibberapp.online,DNS:discord.gibberapp.online,DNS:matrix.gibberapp.online,DNS:irc.gibberapp.online\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" > /certs/ext.cnf && \
    openssl x509 -req -in /certs/gibberapp.online.csr \
      -CA /certs/gibber-ca.crt -CAkey /certs/gibber-ca.key -CAcreateserial \
      -days 3650 -out /certs/gibberapp.online.crt -extfile /certs/ext.cnf || true && \
    openssl x509 -req -in /certs/gibberapp.online.csr \
      -CA /certs/gibber-ca.crt -CAkey /certs/gibber-ca.key -CAcreateserial \
      -days 3650 -out /certs/gibberapp.online.crt -extfile /certs/ext.cnf \
      -extfile /certs/ext.cnf && ls -la /certs/

FROM prosodyim/prosody:13.0
RUN apt-get update && apt-get install -y --no-install-recommends curl socat git cron && rm -rf /var/lib/apt/lists/*
# The cert volume shadows /etc/prosody/certs at runtime and never re-seeds,
# so keep the baked certs in a separate path and sync them at startup.
COPY --from=certgen /certs/ /usr/share/prosody-baked-certs/
RUN chown -R prosody:prosody /etc/prosody/certs

# Vendored community module: XEP-0356 Privileged Entity (lets the slidge
# gateway components manage user rosters + pubsub, so legacy contacts and
# MDS data appear on the user's account automatically).
COPY modules_custom/mod_privilege.lua /usr/lib/prosody/modules/mod_privilege.lua
# Minimal offline push trigger (the upstream http_push module is no longer
# packaged in the 13.0 monolith image).
COPY modules_custom/mod_gibber_push.lua /usr/lib/prosody/modules/mod_gibber_push.lua

# Gateway components mount the cert volume read-only to trust the prosody
# TLS endpoint (for file-share uploads); make the directory traversable.
RUN printf '#!/bin/sh\nfor f in /usr/share/prosody-baked-certs/gibber-ca.crt /usr/share/prosody-baked-certs/gibber-ca.key /usr/share/prosody-baked-certs/gibberapp.online.crt /usr/share/prosody-baked-certs/gibberapp.online.key; do\n  base=$(basename "$f")\n  if ! cmp -s "$f" "/etc/prosody/certs/$base"; then\n    cp -f "$f" "/etc/prosody/certs/$base"\n  fi\ndone\nchmod 755 /etc/prosody/certs\nchmod 644 /etc/prosody/certs/*.crt 2>/dev/null\nchmod 640 /etc/prosody/certs/*.key 2>/dev/null\nchown -R prosody:prosody /etc/prosody/certs 2>/dev/null\nexec /usr/bin/tini -- /entrypoint.sh "$@"\n' > /certfix.sh && chmod +x /certfix.sh
ENTRYPOINT ["/bin/sh", "/certfix.sh"]
CMD ["prosody", "-F"]

# Self-signed TLS only: the compose stack is local-first (no ACME/DNS API).
# The baked self-signed cert covers the XMPP domain; S2S federation from other
# servers will not validate against it (acceptable for local/private setups).