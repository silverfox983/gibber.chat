FROM dart:stable AS build
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
    curl \
    gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Copy the entire bundle preserving directory structure (binary + native libs)
COPY --from=build /app/build/bundle/ /app/

# Create symlinks so libsqlite3 can be found regardless of lookup path
RUN ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /app/lib/libsqlite3.so || true && \
    ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /lib/x86_64-linux-gnu/libsqlite3.so.0 || true && \
    ldconfig || true

COPY config/ /app/config/
RUN mkdir -p /app/data
EXPOSE 8080
CMD ["/app/bin/server", "--host", "0.0.0.0", "--port", "8080", "--db-path", "/app/data/gibber_backend.db", "--config", "/app/config/prosody.cfg.lua", "--use-docker"]