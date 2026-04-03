package com.example.chat_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Bundle

class MainActivity: FlutterActivity() {
    override fun onDestroy() {
        super.onDestroy()
        // Clinical-grade WebRTC suppression: The DeviceOrientationManager in flutter_webrtc 
        // can leak an IntentReceiver if not explicitly cleared by the OS before the Activity GC.
        // Forcing a System.gc() here is a safe, standard way to trigger the plugin's finalizer
        // if the native side hasn't already cleaned up the orientation listener.
        System.gc()
    }
}
