package com.gibber.desertrobotservices

import com.gibber.desertrobotservices.audio.AudioEffectsPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.os.Bundle

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AudioEffectsPlugin())
    }

    override fun onDestroy() {
        super.onDestroy()
        System.gc()
    }
}