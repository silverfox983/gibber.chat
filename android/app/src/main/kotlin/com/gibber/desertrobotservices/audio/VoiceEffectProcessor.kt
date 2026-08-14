package com.gibber.desertrobotservices.audio

import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.min
import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.sqrt
import kotlin.math.sin

class VoiceEffectProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {

    companion object {
        private const val TAG = "VoiceEffectProcessor"
    }

    enum class Effect {
        NONE, PITCH, ROBOT, PHONE, NOISEGATE, CUSTOM
    }

    @Volatile var effect: Effect = Effect.NONE
    @Volatile var pitchSemitones: Float = 0f
    @Volatile var robotDepth: Float = 0.5f
    @Volatile var robotFrequencyHz: Float = 50f
    @Volatile var phoneEnabled: Boolean = false
    @Volatile var noiseGateEnabled: Boolean = false
    @Volatile var noiseGateThresholdDb: Float = -55f
    @Volatile var noiseGateAttackMs: Float = 5f
    @Volatile var noiseGateReleaseMs: Float = 50f
    @Volatile var enabled: Boolean = true

    private var sonic: Sonic = Sonic()
    private var initialized = false
    var currentSampleRate = 0
        private set
    private var processCallCount = 0

    private var firCoeffs: FloatArray = FloatArray(0)
    private var firHistory: FloatArray = FloatArray(0)
    private var firIndex = 0

    private var robotPhase = 0.0

    private var gateEnvelope = 1.0f

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        if (sampleRateHz == currentSampleRate && initialized) return
        currentSampleRate = sampleRateHz
        sonic = Sonic()
        sonic.initialize(sampleRateHz, 1)
        computeFirCoeffs(sampleRateHz)
        gateEnvelope = 1.0f
        robotPhase = 0.0
        initialized = true
        Log.e(TAG, "initialize: rate=$sampleRateHz")
    }

    override fun reset(newRate: Int) {
        Log.e(TAG, "reset: newRate=$newRate")
        if (newRate != currentSampleRate) {
            currentSampleRate = newRate
            sonic = Sonic()
            sonic.initialize(newRate, 1)
            computeFirCoeffs(newRate)
        }
        sonic.reset()
        robotPhase = 0.0
        gateEnvelope = 1.0f
        firIndex = 0
        firHistory = FloatArray(firCoeffs.size)
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        if (!initialized && numFrames > 0) {
            val inferredRate = numFrames * 100
            if (inferredRate >= 8000 && inferredRate <= 96000) {
                Log.e(TAG, "Self-initializing with inferred rate=$inferredRate from numFrames=$numFrames")
                initialize(inferredRate, 1)
            }
        }
        if (!enabled) return
        if (effect == Effect.NONE && !phoneEnabled && !noiseGateEnabled) return
        if (!initialized || currentSampleRate == 0 || firCoeffs.isEmpty()) return
        if (buffer.remaining() < numFrames * 4) return

        processCallCount++
        if (processCallCount <= 5 || processCallCount % 300 == 0) {
            Log.e(TAG, "process: effect=$effect frames=$numFrames rate=$currentSampleRate pitch=$pitchSemitones robot=$robotDepth@$robotFrequencyHz phone=$phoneEnabled gate=$noiseGateEnabled")
        }

        buffer.order(ByteOrder.LITTLE_ENDIAN)

        val samples = ShortArray(numFrames)
        for (i in 0 until numFrames) {
            samples[i] = buffer.getFloat(i * 4).toInt().coerceIn(-32768, 32767).toShort()
        }

        if (noiseGateEnabled) {
            applyNoiseGate(samples, numFrames)
        }

        val effectiveEffect = effect
        if (effectiveEffect == Effect.PITCH || effectiveEffect == Effect.CUSTOM) {
            applyPitchShift(samples, numFrames)
        }

        if (effectiveEffect == Effect.ROBOT || effectiveEffect == Effect.CUSTOM) {
            applyRobot(samples, numFrames)
        }

        if (phoneEnabled || effectiveEffect == Effect.PHONE) {
            applyFirBandpass(samples, numFrames)
        }

        for (i in 0 until numFrames) {
            buffer.putFloat(i * 4, samples[i].toFloat())
        }
    }

    private fun applyPitchShift(samples: ShortArray, numFrames: Int) {
        val semitones = pitchSemitones
        if (semitones == 0f) return
        val pitchFactor = 2.0.pow(semitones.toDouble() / 12.0).toFloat().coerceIn(0.5f, 2.0f)
        sonic.pitch = pitchFactor
        sonic.processFrame(samples, numFrames)
    }

    private fun applyRobot(samples: ShortArray, numFrames: Int) {
        val depth = robotDepth
        val freq = robotFrequencyHz.toDouble()
        val phaseStep = freq / currentSampleRate
        for (i in 0 until numFrames) {
            val mod = sin(2.0 * PI * robotPhase)
            robotPhase += phaseStep
            if (robotPhase >= 1.0) robotPhase -= 1.0
            val s = samples[i].toInt()
            val modulated = s * (1.0 - depth + depth * mod)
            samples[i] = modulated.toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
    }

    private fun applyNoiseGate(samples: ShortArray, numFrames: Int) {
        if (numFrames == 0 || currentSampleRate == 0) return

        var sumSquares = 0L
        for (i in 0 until numFrames) {
            val s = samples[i].toInt()
            sumSquares += s.toLong() * s.toLong()
        }
        val rms = sqrt(sumSquares.toDouble() / numFrames)
        val dbfs = if (rms > 0) 20.0 * ln(rms / 32768.0) / ln(10.0) else -96.0

        val attackCoeff = 1.0f - (1.0f / (1.0f + (currentSampleRate.toFloat() / numFrames.toFloat()) * noiseGateAttackMs / 1000.0f))
        val releaseCoeff = 1.0f - (1.0f / (1.0f + (currentSampleRate.toFloat() / numFrames.toFloat()) * noiseGateReleaseMs / 1000.0f))

        val target = if (dbfs < noiseGateThresholdDb) 0.05f else 1.0f
        if (target > gateEnvelope) {
            gateEnvelope += (target - gateEnvelope) * attackCoeff
        } else {
            gateEnvelope += (target - gateEnvelope) * releaseCoeff
        }
        gateEnvelope = gateEnvelope.coerceIn(0.05f, 1.0f)

        for (i in 0 until numFrames) {
            samples[i] = (samples[i].toInt() * gateEnvelope).toInt().toShort()
        }
    }

    private fun computeFirCoeffs(sampleRate: Int) {
        val numTaps = 64
        firCoeffs = FloatArray(numTaps)
        firHistory = FloatArray(numTaps)
        firIndex = 0

        val lowCut = 300.0
        val highCut = 3400.0
        val lowNorm = lowCut / sampleRate
        val highNorm = highCut / sampleRate

        var sum = 0.0
        for (i in 0 until numTaps) {
            val n = i - numTaps / 2
            var h = 0.0
            if (n != 0) {
                val sincHigh = sin(2.0 * PI * highNorm * n) / (PI * n)
                val sincLow = sin(2.0 * PI * lowNorm * n) / (PI * n)
                h = sincHigh - sincLow
            } else {
                h = 2.0 * (highNorm - lowNorm)
            }
            val w = 0.54 - 0.46 * cos(2.0 * PI * i / (numTaps - 1))
            firCoeffs[i] = (h * w).toFloat()
            sum += abs(h * w)
        }

        if (sum > 0) {
            for (i in firCoeffs.indices) {
                firCoeffs[i] /= sum.toFloat()
            }
        }
    }

    private fun applyFirBandpass(samples: ShortArray, numFrames: Int) {
        val taps = firCoeffs.size
        for (i in 0 until numFrames) {
            firHistory[firIndex] = samples[i].toFloat()
            var acc = 0.0f
            for (j in 0 until taps) {
                val idx = (firIndex - j + taps) % taps
                acc += firCoeffs[j] * firHistory[idx]
            }
            firIndex = (firIndex + 1) % taps
            samples[i] = acc.coerceIn(Short.MIN_VALUE.toFloat(), Short.MAX_VALUE.toFloat()).toInt().toShort()
        }
    }
}