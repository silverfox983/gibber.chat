# Flutter web build for the Gibber web app.
# Builds the static site, then copies it INTO the shared web_build volume at
# container start (named volumes only seed from the image on FIRST mount, so a
# runtime copy is required for every rebuild).

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
COPY --from=build /app/build/web /site
CMD ["sh", "-c", "rm -rf /web/* && cp -r /site/. /web/ && echo 'web_build volume refreshed'"]