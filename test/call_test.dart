import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/services/webrtc_manager.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('WebRTCManager can be instantiated', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );

    // Verify WebRTCManager can be created without throwing
    final webrtcManager = WebRTCManager();
    expect(webrtcManager, isNotNull);

    // Test initial state
    expect(webrtcManager.isDisposed, isFalse);

    // Avoid awaiting plugin disposal in tests; native cleanup can hang in CI.
    unawaited(webrtcManager.dispose());
  });

  testWidgets('Audio level monitoring works', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );

    final webrtcManager = WebRTCManager();

    // Test that audioLevels getter returns a stream
    expect(webrtcManager.audioLevels, isNotNull);

    // Avoid awaiting plugin disposal in tests; native cleanup can hang in CI.
    unawaited(webrtcManager.dispose());
  });
}
