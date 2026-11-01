# Flutter web build for the Gibber web app.
# Produces /web with the static site; the caddy/backend services mount it.

FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app
COPY pubspec.yaml ./
COPY packages packages
RUN flutter pub get
COPY lib lib
COPY web web
COPY assets assets
COPY analysis_options.yaml ./
RUN flutter build web --release --no-tree-shake-icons

FROM busybox:stable AS site
COPY --from=build /app/build/web /web