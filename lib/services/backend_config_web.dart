import 'dart:js_interop';

import 'package:web/web.dart' show window;

/// On web the site is served by the backend itself, so the backend URL is
/// always the page origin. This makes local/self-hosted deployments work
/// without pointing at a remote server.
String? get sameOriginApiUrl {
  final origin = window.location.origin;
  if (origin.isEmpty || origin == 'null') return null;
  return origin;
}