# biboumi built WITHOUT udns: biboumi's udns resolver misbehaves in some
# container/DNS environments (Docker embedded DNS); without udns it falls
# back to plain getaddrinfo (musl), which works everywhere.
FROM alpine:3.21 AS build

RUN apk add --no-cache \
      git \
      build-base \
      cmake \
      botan-dev \
      expat-dev \
      libidn-dev \
      sqlite-dev \
      sqlite-libs \
      util-linux-dev

RUN git clone --depth 1 --branch 9.0 https://github.com/louiz/biboumi /src/biboumi
WORKDIR /src/biboumi
RUN mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr >/dev/null && \
    make -j"$(nproc)" >/dev/null && \
    make install >/dev/null && \
    strip /usr/bin/biboumi

FROM alpine:3.21
RUN apk add --no-cache botan expat libidn sqlite sqlite-libs libuuid libpq ca-certificates && \
    mkdir -p /var/lib/biboumi /etc/biboumi
COPY --from=build /usr/bin/biboumi /usr/bin/biboumi
ENTRYPOINT ["/usr/bin/biboumi", "/etc/biboumi/biboumi.cfg"]