import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/services/webrtc_manager.dart';

void main() {
  test('WebRTCManager can be instantiated', () {
    final webrtcManager = WebRTCManager();
    expect(webrtcManager, isNotNull);
    expect(webrtcManager.isDisposed, isFalse);
  });

  test('WebRTCManager audio level stream is available', () {
    final webrtcManager = WebRTCManager();
    expect(webrtcManager.audioLevels, isNotNull);
  });
}
