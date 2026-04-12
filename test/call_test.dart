import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/services/webrtc_manager.dart';

void main() {
  test('WebRTCManager can be instantiated', () {
    final webrtcManager = WebRTCManager();
    expect(webrtcManager, isNotNull);
    expect(webrtcManager.isDisposed, isFalse);

    // Avoid dispose here; dispose schedules delayed timers that fail widget-test invariants.
  });

  test('WebRTCManager audio level stream is available', () {
    final webrtcManager = WebRTCManager();
    expect(webrtcManager.audioLevels, isNotNull);

    // Avoid dispose here; dispose schedules delayed timers that fail widget-test invariants.
  });
}
