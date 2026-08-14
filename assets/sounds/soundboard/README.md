# Soundboard Assets

Place audio files here to use them in the "Play Audio Over Call" feature.

## Supported formats
MP3, AAC, OGG, WAV, FLAC, M4A — any format decodable by Android's MediaCodec.

## How to use
1. Copy audio files into this directory.
2. Run `flutter clean && flutter pub get` to refresh the asset bundle.
3. During a call, tap **Play** → the asset files will appear as options.

## Note
Keep files small (< 5 MB recommended). Large files increase APK size.
Files placed here are bundled with the app and available offline.