package com.gibber.desertrobotservices.audio

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class AudioEffectsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "AudioEffectsPlugin"
        private const val CHANNEL = "gibber.audio_effects"
        private const val MAX_REGISTRATION_RETRIES = 30
        private const val REGISTRATION_RETRY_DELAY_MS = 500L
    }

    private lateinit var context: Context
    private var methodChannel: MethodChannel? = null
    private var webrtcPlugin: FlutterWebRTCPlugin? = null

    val voiceEffectProcessor = VoiceEffectProcessor()
    val audioInjector = AudioInjector()

    private var registeredToWebRTC = false
    private var registrationRetryCount = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler(this)

        registerProcessorsWithRetry()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        audioInjector.stopDecoding()
        unregisterProcessors()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        webrtcPlugin = null
    }

    private fun registerProcessorsWithRetry() {
        if (registeredToWebRTC) return

        webrtcPlugin = FlutterWebRTCPlugin.sharedSingleton
        if (webrtcPlugin == null) {
            registrationRetryCount++
            if (registrationRetryCount <= MAX_REGISTRATION_RETRIES) {
                Log.w(TAG, "FlutterWebRTCPlugin not found, retry ${registrationRetryCount}/$MAX_REGISTRATION_RETRIES in ${REGISTRATION_RETRY_DELAY_MS}ms")
                Handler(Looper.getMainLooper()).postDelayed({
                    registerProcessorsWithRetry()
                }, REGISTRATION_RETRY_DELAY_MS)
            } else {
                Log.e(TAG, "FlutterWebRTCPlugin not found after $MAX_REGISTRATION_RETRIES retries. Audio effects will not work until a method call triggers lazy registration.")
            }
            return
        }

        val controller = try {
            webrtcPlugin!!.audioProcessingController
        } catch (e: Exception) {
            Log.w(TAG, "audioProcessingController not available yet, retry ${registrationRetryCount}/$MAX_REGISTRATION_RETRIES")
            registrationRetryCount++
            if (registrationRetryCount <= MAX_REGISTRATION_RETRIES) {
                Handler(Looper.getMainLooper()).postDelayed({
                    registerProcessorsWithRetry()
                }, REGISTRATION_RETRY_DELAY_MS)
            }
            return
        }

        if (controller == null) {
            Log.w(TAG, "audioProcessingController is null (WebRTC not initialized), retry ${registrationRetryCount}/$MAX_REGISTRATION_RETRIES")
            registrationRetryCount++
            if (registrationRetryCount <= MAX_REGISTRATION_RETRIES) {
                Handler(Looper.getMainLooper()).postDelayed({
                    registerProcessorsWithRetry()
                }, REGISTRATION_RETRY_DELAY_MS)
            }
            return
        }

        try {
            val adapter = controller.capturePostProcessing
            adapter.addProcessor(voiceEffectProcessor)
            adapter.addProcessor(audioInjector)
            registeredToWebRTC = true
            Log.e(TAG, "VoiceEffectProcessor and AudioInjector registered to WebRTC pipeline")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register processors", e)
        }
    }

    private fun ensureRegistered() {
        if (registeredToWebRTC) return

        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: return

        val controller = try {
            plugin.audioProcessingController
        } catch (e: Exception) {
            return
        } ?: return

        try {
            val adapter = controller.capturePostProcessing
            adapter.addProcessor(voiceEffectProcessor)
            adapter.addProcessor(audioInjector)
            registeredToWebRTC = true
            Log.e(TAG, "Processors registered lazily to WebRTC pipeline via ensureRegistered()")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register processors lazily", e)
        }
    }

    private fun unregisterProcessors() {
        if (!registeredToWebRTC) return
        try {
            val plugin = webrtcPlugin ?: return
            val controller = try {
                plugin.audioProcessingController
            } catch (e: Exception) {
                return
            } ?: return
            val adapter = controller.capturePostProcessing
            adapter.removeProcessor(voiceEffectProcessor)
            adapter.removeProcessor(audioInjector)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister processors", e)
        }
        registeredToWebRTC = false
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!registeredToWebRTC) {
            ensureRegistered()
        }

        try {
            when (call.method) {
                "setEffect" -> {
                    val effectName = call.argument<String>("effect") ?: "NONE"
                    voiceEffectProcessor.effect = VoiceEffectProcessor.Effect.valueOf(effectName)
                    Log.e(TAG, "setEffect: $effectName (initialized=${voiceEffectProcessor.currentSampleRate != 0}, registered=$registeredToWebRTC)")
                    result.success(null)
                }
                "setPitchSemitones" -> {
                    val semitones = call.argument<Double>("semitones")?.toFloat() ?: 0f
                    voiceEffectProcessor.pitchSemitones = semitones
                    result.success(null)
                }
                "setRobotDepth" -> {
                    val depth = call.argument<Double>("depth")?.toFloat() ?: 0.5f
                    voiceEffectProcessor.robotDepth = depth
                    result.success(null)
                }
                "setRobotFrequency" -> {
                    val freq = call.argument<Double>("frequency")?.toFloat() ?: 50f
                    voiceEffectProcessor.robotFrequencyHz = freq
                    result.success(null)
                }
                "setPhoneFilter" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    voiceEffectProcessor.phoneEnabled = enabled
                    result.success(null)
                }
                "setNoiseGate" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    voiceEffectProcessor.noiseGateEnabled = enabled
                    result.success(null)
                }
                "setNoiseGateThreshold" -> {
                    val thresholdDb = call.argument<Double>("thresholdDb")?.toFloat() ?: -55f
                    voiceEffectProcessor.noiseGateThresholdDb = thresholdDb
                    result.success(null)
                }
                "setEffectEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    voiceEffectProcessor.enabled = enabled
                    result.success(null)
                }
                "resetEffects" -> {
                    voiceEffectProcessor.effect = VoiceEffectProcessor.Effect.NONE
                    voiceEffectProcessor.pitchSemitones = 0f
                    voiceEffectProcessor.robotDepth = 0.5f
                    voiceEffectProcessor.robotFrequencyHz = 50f
                    voiceEffectProcessor.phoneEnabled = false
                    voiceEffectProcessor.noiseGateEnabled = false
                    voiceEffectProcessor.noiseGateThresholdDb = -55f
                    voiceEffectProcessor.enabled = true
                    voiceEffectProcessor.reset(voiceEffectProcessor.currentSampleRate)
                    result.success(null)
                }

                "playAudioOverCall" -> {
                    val path = call.argument<String>("path")
                    val isAsset = call.argument<Boolean>("isAsset") ?: false
                    val isUrl = call.argument<Boolean>("isUrl") ?: false
                    val looping = call.argument<Boolean>("looping") ?: false
                    val volume = call.argument<Double>("volume")?.toFloat() ?: 0.7f
                    if (path == null) {
                        result.error("INVALID_ARGS", "path is required", null)
                        return
                    }
                    audioInjector.stopDecoding()
                    audioInjector.setDataSource(path, isAsset, isUrl)
                    audioInjector.looping = looping
                    audioInjector.mixVolume = volume
                    audioInjector.startDecoding(context)
                    result.success(null)
                }
                "pauseAudioOverCall" -> {
                    audioInjector.pause()
                    result.success(null)
                }
                "resumeAudioOverCall" -> {
                    audioInjector.resume()
                    result.success(null)
                }
                "stopAudioOverCall" -> {
                    audioInjector.stopDecoding()
                    result.success(null)
                }
                "seekAudioOverCall" -> {
                    val ratio = call.argument<Double>("ratio")?.toFloat() ?: 0f
                    audioInjector.seekTo(ratio)
                    result.success(null)
                }
                "setAudioOverCallVolume" -> {
                    val volume = call.argument<Double>("volume")?.toFloat() ?: 0.7f
                    audioInjector.mixVolume = volume
                    result.success(null)
                }
                "setAudioOverCallLooping" -> {
                    val looping = call.argument<Boolean>("looping") ?: false
                    audioInjector.looping = looping
                    result.success(null)
                }
                "getAudioOverCallDuration" -> {
                    result.success(audioInjector.getDurationMs())
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling method call ${call.method}", e)
            result.error("AUDIO_EFFECTS_ERROR", e.message, null)
        }
    }
}