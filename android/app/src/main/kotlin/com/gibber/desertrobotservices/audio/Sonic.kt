package com.gibber.desertrobotservices.audio

import kotlin.math.cos
import kotlin.math.min
import kotlin.math.PI
import kotlin.math.pow

class Sonic {

    companion object {
        private const val MIN_PITCH = 0.5f
        private const val MAX_PITCH = 2.0f
        private const val MAX_OUTPUT_SAMPLES = 9600
    }

    @Volatile var pitch = 1.0f

    private var sampleRate = 48000
    private var grainSize = 320
    private var hopOut = 160
    private var hannWindow = FloatArray(0)
    private var initialized = false

    private var inBuf = FloatArray(4096)
    private var inCount = 0

    private var outBuf = FloatArray(16384)
    private var outHead = 0
    private var outTail = 0

    private var hopInFrac = 0.0f

    fun initialize(sampleRateHz: Int, numChannels: Int) {
        this.sampleRate = sampleRateHz
        grainSize = (sampleRateHz * 0.02f).toInt().coerceIn(128, 640) and 0xFFFE
        hopOut = grainSize / 2
        hannWindow = FloatArray(grainSize) { i ->
            (0.5 * (1.0 - cos(2.0 * PI * i / (grainSize - 1)))).toFloat()
        }
        reset()
        initialized = true
    }

    fun reset() {
        inBuf = FloatArray(4096)
        inCount = 0
        outBuf = FloatArray(16384)
        outHead = 0
        outTail = 0
        hopInFrac = 0.0f
    }

    fun processFrame(samples: ShortArray, numFrames: Int) {
        if (pitch == 1.0f || numFrames == 0) return
        if (!initialized) initialize(16000, 1)

        val pitchFactor = pitch.coerceIn(MIN_PITCH, MAX_PITCH)

        val inNeeded = inCount + numFrames
        if (inNeeded > inBuf.size) {
            inBuf = inBuf.copyOf(inNeeded * 2)
        }
        for (i in 0 until numFrames) {
            inBuf[inCount++] = samples[i].toFloat()
        }

        while (inCount >= grainSize && (outHead - outTail) < MAX_OUTPUT_SAMPLES) {
            hopInFrac += hopOut * pitchFactor
            val hopIn = hopInFrac.toInt().coerceIn(1, grainSize * 4)
            hopInFrac -= hopIn

            val neededSpace = outHead + grainSize
            if (neededSpace > outBuf.size) {
                compactOut()
            }
            if (outHead + grainSize > outBuf.size) {
                outBuf = FloatArray(outBuf.size * 2)
                outHead = 0
                outTail = 0
            }

            for (i in 0 until grainSize) {
                outBuf[outHead + i] += inBuf[i] * hannWindow[i]
            }
            outHead += hopOut

            val consumed = hopIn.coerceAtMost(inCount)
            System.arraycopy(inBuf, consumed, inBuf, 0, inCount - consumed)
            inCount -= consumed
        }

        val avail = outHead - outTail
        val toRead = min(numFrames, avail)

        for (i in 0 until toRead) {
            samples[i] = outBuf[outTail + i].toInt().coerceIn(-32768, 32767).toShort()
            outBuf[outTail + i] = 0f
        }
        outTail += toRead

        if (outTail > grainSize * 8) {
            compactOut()
        }

        if (toRead < numFrames) {
            val lastVal = if (toRead > 0) samples[toRead - 1] else 0
            for (i in toRead until numFrames) {
                samples[i] = lastVal
            }
        }
    }

    private fun compactOut() {
        val dataLen = outHead - outTail
        if (dataLen <= 0) {
            outBuf = FloatArray(16384)
            outHead = 0
            outTail = 0
            return
        }
        val overlapLen = min(grainSize, outBuf.size - outHead)
        val totalLen = dataLen + overlapLen
        val newBuf = FloatArray(maxOf(outBuf.size, totalLen * 2))
        for (i in 0 until dataLen) {
            newBuf[i] = outBuf[outTail + i]
        }
        for (i in 0 until overlapLen) {
            newBuf[dataLen + i] = outBuf[outHead + i]
        }
        outBuf = newBuf
        outHead = dataLen + overlapLen
        outTail = 0
    }
}