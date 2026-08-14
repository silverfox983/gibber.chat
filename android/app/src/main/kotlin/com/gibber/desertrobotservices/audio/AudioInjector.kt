package com.gibber.desertrobotservices.audio

import android.content.res.AssetFileDescriptor
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.min

class AudioInjector : AudioProcessingAdapter.ExternalAudioFrameProcessing {

    companion object {
        private const val TAG = "AudioInjector"
        private const val RING_SIZE = 192000
        private const val RING_HIGH_WATER = RING_SIZE * 3 / 4
    }

    @Volatile var mixVolume: Float = 0.7f
    @Volatile var looping: Boolean = false
    @Volatile var playing: Boolean = false

    private val ringBuffer = ShortArray(RING_SIZE)
    @Volatile private var ringWriteCount: Long = 0
    @Volatile private var ringReadCount: Long = 0

    private var sampleRate = 48000
    private var channels = 1
    private var initialized = false

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var decodeThread: HandlerThread? = null
    private var decodeHandler: Handler? = null
    @Volatile private var isDecoding = false
    @Volatile private var stopRequested = false
    private var sourcePath: String? = null
    private var sourceIsAsset: Boolean = false
    private var sourceIsUrl: Boolean = false

    private var resampleRatio: Float = 1.0f
    private var resamplePhase: Float = 0.0f

    @Volatile private var cachedDurationMs: Long = 0L
    private var firstSampleWritten = false

    private var fadeOutPhase: Float = 1.0f
    private var lastInjectedSample: Short = 0
    private var fadeInSamplesRemaining: Int = 0

    private val ringAvailable: Int
        get() = (ringWriteCount - ringReadCount).toInt().coerceIn(0, RING_SIZE)

    fun setDataSource(path: String, isAsset: Boolean = false, isUrl: Boolean = false) {
        stopDecoding()
        sourcePath = path
        sourceIsAsset = isAsset
        sourceIsUrl = isUrl
    }

    fun startDecoding(context: android.content.Context? = null) {
        if (sourcePath == null) return
        stopDecoding()
        ringWriteCount = 0
        ringReadCount = 0
        fadeOutPhase = 1.0f
        lastInjectedSample = 0
        fadeInSamplesRemaining = 240
        firstSampleWritten = false
        decodeThread = HandlerThread("AudioInjectorDecode").also { it.start() }
        decodeHandler = Handler(decodeThread!!.looper)
        decodeHandler!!.post {
            try {
                startDecodingInternal(context)
            } catch (e: Exception) {
                Log.e(TAG, "Decode error", e)
                isDecoding = false
            } finally {
                cleanupCodec()
            }
        }
    }

    fun stopDecoding() {
        isDecoding = false
        stopRequested = true
        playing = false

        val thread = decodeThread
        if (thread != null && thread.isAlive) {
            thread.quitSafely()
            try {
                thread.join(3000)
            } catch (_: InterruptedException) {}
        }
        cleanupCodec()

        decodeThread = null
        decodeHandler = null
        stopRequested = false
    }

    private fun cleanupCodec() {
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        try { extractor?.release() } catch (_: Exception) {}
        codec = null
        extractor = null
    }

    fun pause() {
        playing = false
    }

    fun resume() {
        if (sourcePath != null && (isDecoding || ringAvailable > 0)) playing = true
    }

    fun seekTo(ratio: Float) {
        val avail = ringAvailable
        val offset = (ratio * avail).toInt().coerceIn(0, avail)
        ringReadCount = ringWriteCount - avail + offset
    }

    fun getDurationMs(): Long = cachedDurationMs

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        Log.e(TAG, "initialize: rate=$sampleRateHz ch=$numChannels")
        sampleRate = sampleRateHz
        channels = numChannels
        initialized = true
    }

    override fun reset(newRate: Int) {
        Log.e(TAG, "reset: newRate=$newRate")
        sampleRate = newRate
        resamplePhase = 0.0f
    }

    private var processCallCount = 0

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        // Self-initialize if WebRTC's initialize() was called before we were registered
        if (!initialized && numFrames > 0) {
            val inferredRate = numFrames * 100
            if (inferredRate >= 8000 && inferredRate <= 96000) {
                Log.e(TAG, "Self-initializing with inferred rate=$inferredRate ch=1 from numFrames=$numFrames")
                initialize(inferredRate, 1)
            }
        }
        if (buffer.remaining() < numFrames * 4) return

        processCallCount++
        if (processCallCount <= 5 || processCallCount % 200 == 0) {
            Log.e(TAG, "process: playing=$playing isDecoding=$isDecoding ringAvail=${ringAvailable} frames=$numFrames rate=$sampleRate mixVol=$mixVolume")
        }

        val avail = ringAvailable
        if (!playing || avail <= 0) {
            if (playing && !isDecoding && avail <= 0) {
                playing = false
            }
            if (fadeOutPhase < 1.0f && lastInjectedSample != 0.toShort()) {
                buffer.order(ByteOrder.LITTLE_ENDIAN)
                for (i in 0 until numFrames) {
                    fadeOutPhase += 1.0f / 144f
                    if (fadeOutPhase >= 1.0f) {
                        lastInjectedSample = 0
                        fadeOutPhase = 1.0f
                        break
                    }
                    val mic = buffer.getFloat(i * 4)
                    val mixed = mic + lastInjectedSample * mixVolume * fadeOutPhase
                    buffer.putFloat(i * 4, mixed.coerceIn(-32768.0f, 32767.0f))
                }
            }
            return
        }

        buffer.order(ByteOrder.LITTLE_ENDIAN)
        val mixVol = mixVolume
        val samplesToMix = min(numFrames, avail)

        for (i in 0 until numFrames) {
            val mic = buffer.getFloat(i * 4)
            if (i < samplesToMix) {
                val inj = ringBuffer[(ringReadCount + i).toInt() % RING_SIZE].toInt()
                lastInjectedSample = inj.toShort()
                val fadeIn = if (fadeInSamplesRemaining > 0) {
                    val progress = (240 - fadeInSamplesRemaining + i).coerceIn(0, 240).toFloat() / 240f
                    progress.coerceIn(0f, 1f)
                } else 1.0f
                val mixed = mic + inj * mixVol * fadeIn
                buffer.putFloat(i * 4, mixed.coerceIn(-32768.0f, 32767.0f))
            } else {
                val underrunOffset = i - samplesToMix
                val fadeOut = if (underrunOffset < 144) {
                    1.0f - underrunOffset.toFloat() / 144f
                } else {
                    0.0f
                }
                val mixed = mic + lastInjectedSample.toInt() * mixVol * fadeOut
                buffer.putFloat(i * 4, mixed.coerceIn(-32768.0f, 32767.0f))
            }
        }

        if (fadeInSamplesRemaining > 0) {
            fadeInSamplesRemaining = (fadeInSamplesRemaining - samplesToMix).coerceAtLeast(0)
        }

        ringReadCount += samplesToMix

        if (samplesToMix < numFrames && numFrames > 0) {
            fadeOutPhase = (numFrames - samplesToMix).toFloat() / 144f
            if (fadeOutPhase >= 1.0f) {
                lastInjectedSample = 0
                fadeOutPhase = 1.0f
            }
        }
    }

    private fun startDecodingInternal(context: android.content.Context?) {
        isDecoding = true
        stopRequested = false
        val path = sourcePath ?: return

        extractor = MediaExtractor()
        try {
            when {
                sourceIsUrl -> extractor!!.setDataSource(path)
                sourceIsAsset && context != null -> {
                    val afd: AssetFileDescriptor = context.assets.openFd(path)
                    extractor!!.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                    afd.close()
                }
                else -> {
                    if (path.startsWith("content://") || path.startsWith("file://") || path.startsWith("/")) {
                        extractor!!.setDataSource(path)
                    } else {
                        val fis = FileInputStream(path)
                        extractor!!.setDataSource(fis.fd)
                        fis.close()
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set data source: $path", e)
            isDecoding = false
            return
        }

        var audioTrack = -1
        for (i in 0 until extractor!!.trackCount) {
            val fmt = extractor!!.getTrackFormat(i)
            if (fmt.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                audioTrack = i
                break
            }
        }
        if (audioTrack == -1) {
            Log.e(TAG, "No audio track found in: $path")
            isDecoding = false
            return
        }

        extractor!!.selectTrack(audioTrack)
        val format = extractor!!.getTrackFormat(audioTrack)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: run {
            isDecoding = false
            return
        }

        val srcSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        resampleRatio = srcSampleRate.toFloat() / sampleRate.toFloat()

        cachedDurationMs = try {
            format.getLong(MediaFormat.KEY_DURATION) / 1000
        } catch (_: Exception) { 0L }

        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65536)

        try {
            codec = MediaCodec.createDecoderByType(mime)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create decoder for mime: $mime", e)
            isDecoding = false
            return
        }

        try {
            codec!!.configure(format, null, null, 0)
            codec!!.start()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure/start decoder", e)
            codec?.release()
            codec = null
            isDecoding = false
            return
        }

        playing = true
        Log.e(TAG, "Decode starting: playing=$playing looping=$looping srcRate=$srcSampleRate srcCh=$srcChannels dstRate=$sampleRate")
        decodeLoop(srcSampleRate, srcChannels)

        if (!looping) {
            isDecoding = false
            Log.e(TAG, "Decode finished (non-looping), ring buffer will drain naturally")
        }
    }

    private fun decodeLoop(srcSampleRate: Int, srcChannels: Int) {
        val dec = codec ?: return
        val ext = extractor ?: return
        val timeoutUs = 10000L
        val bufInfo = MediaCodec.BufferInfo()

        while (isDecoding && !stopRequested) {
            while (ringAvailable >= RING_HIGH_WATER && isDecoding && !stopRequested) {
                try {
                    Thread.sleep(5)
                } catch (_: InterruptedException) {
                    return
                }
            }

            var inputFed = false
            while (!inputFed && isDecoding && !stopRequested) {
                try {
                    val inputIndex = dec.dequeueInputBuffer(timeoutUs)
                    if (inputIndex >= 0) {
                        val inputBuf = dec.getInputBuffer(inputIndex) ?: continue
                        inputBuf.clear()
                        val sampleSize = ext.readSampleData(inputBuf, 0)
                        if (sampleSize < 0) {
                            dec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputFed = true
                        } else {
                            dec.queueInputBuffer(inputIndex, 0, sampleSize, ext.sampleTime, 0)
                            ext.advance()
                            inputFed = true
                        }
                    } else {
                        inputFed = true
                    }
                } catch (e: IllegalStateException) {
                    Log.e(TAG, "Codec stopped during input dequeue", e)
                    return
                }
            }

            if (!isDecoding || stopRequested) break

            var outputDone = false
            while (!outputDone && isDecoding && !stopRequested) {
                val outIndex: Int
                try {
                    outIndex = dec.dequeueOutputBuffer(bufInfo, timeoutUs)
                } catch (e: IllegalStateException) {
                    Log.e(TAG, "Codec stopped during output dequeue", e)
                    return
                }

                if (outIndex >= 0) {
                    if (bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        dec.releaseOutputBuffer(outIndex, false)
                        if (looping && !stopRequested) {
                            ext.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                            try {
                                dec.flush()
                            } catch (_: Exception) {}
                        } else {
                            isDecoding = false
                        }
                        break
                    }

                    val outBuf = dec.getOutputBuffer(outIndex) ?: continue

                    val numBytes = bufInfo.size
                    val numSamples = numBytes / 2
                    if (numSamples == 0) {
                        dec.releaseOutputBuffer(outIndex, false)
                        continue
                    }

                    var sampleIdx = 0
                    var phase = resamplePhase

                    while (sampleIdx < numSamples && isDecoding && !stopRequested) {
                        while (ringAvailable >= RING_HIGH_WATER && isDecoding && !stopRequested) {
                            try {
                                Thread.sleep(2)
                            } catch (_: InterruptedException) {
                                return
                            }
                        }
                        if (!isDecoding || stopRequested) break

                        val sample: Short = if (srcChannels == 2 && sampleIdx + 1 < numSamples) {
                            val l = outBuf.getShort(bufInfo.offset + sampleIdx * 2).toInt()
                            val r = outBuf.getShort(bufInfo.offset + (sampleIdx + 1) * 2).toInt()
                            ((l + r) / 2).toShort()
                        } else {
                            outBuf.getShort(bufInfo.offset + sampleIdx * 2)
                        }

                        if (resampleRatio <= 1.0f) {
                            phase += 1.0f
                            if (phase >= resampleRatio) {
                                phase -= resampleRatio
                                writeRingSample(sample)
                                while (phase >= resampleRatio && isDecoding) {
                                    phase -= resampleRatio
                                    writeRingSample(sample)
                                }
                            }
                        } else {
                            phase += resampleRatio
                            if (phase >= 1.0f) {
                                phase -= 1.0f
                                val nextSampleIdx = sampleIdx + (if (srcChannels == 2) 2 else 1)
                                val nextSample: Short = if (nextSampleIdx < numSamples) {
                                    if (srcChannels == 2 && nextSampleIdx + 1 < numSamples) {
                                        val l = outBuf.getShort(bufInfo.offset + nextSampleIdx * 2).toInt()
                                        val r = outBuf.getShort(bufInfo.offset + (nextSampleIdx + 1) * 2).toInt()
                                        ((l + r) / 2).toShort()
                                    } else {
                                        outBuf.getShort(bufInfo.offset + nextSampleIdx * 2)
                                    }
                                } else {
                                    sample
                                }
                                val frac = phase / resampleRatio
                                val interp = sample.toInt() + frac * (nextSample.toInt() - sample.toInt())
                                writeRingSample(interp.toInt().toShort())
                            }
                        }

                        sampleIdx += if (srcChannels == 2) 2 else 1
                    }
                    resamplePhase = phase

                    dec.releaseOutputBuffer(outIndex, false)
                } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    // continue
                } else if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    outputDone = true
                }
            }
        }
    }

    private fun writeRingSample(sample: Short) {
        val writePos = (ringWriteCount % RING_SIZE).toInt()
        ringBuffer[writePos] = sample
        ringWriteCount++
        if (!firstSampleWritten) {
            firstSampleWritten = true
            Log.e(TAG, "First sample written to ring buffer, playing=$playing isDecoding=$isDecoding")
        }
        if (ringWriteCount - ringReadCount > RING_SIZE) {
            ringReadCount = ringWriteCount - RING_SIZE
        }
    }
}