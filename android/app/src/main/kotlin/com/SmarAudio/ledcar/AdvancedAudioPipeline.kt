package com.SmarAudio.ledcar

import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/**
 * TOP 3 ADVANCED FEATURES FOR LEDCAR
 * 1. BEAT DETECTION
 * 2. ONSET DETECTION
 * 3. EMOTION RECOGNITION
 */

// ============================================================================
// 1. BEAT DETECTION (BPM Extraction + Beat Tracking)
// ============================================================================

class BeatDetector(val sr: Int = 16000, val hopLength: Int = 512) {
    /**
     * Real-time Beat Detection & BPM Extraction
     *
     * - Estimates BPM using autocorrelation of onset strength
     * - Syncs LED pulsing to music tempo
     *
     * Latency: ~20ms
     * Size: ~2 KB code
     *
     * Usage:
     *   val beatDetector = BeatDetector()
     *   for each audio frame:
     *       beatDetector.addOnsetStrength(onsetValue)
     *       val beatInfo = beatDetector.getBeatInfo()
     *       ledSpeed = beatInfo.beatIntervalMs
     */

    private val framesPerSecond = sr / hopLength.toFloat()
    private val onsetBuffer = mutableListOf<Float>()
    private val bufferSize = (framesPerSecond * 5).toInt()  // 5 seconds

    var currentBPM = 0
    var confidence = 0f

    fun addOnsetStrength(onsetValue: Float) {
        onsetBuffer.add(onsetValue.coerceIn(0f, 1f))
        if (onsetBuffer.size > bufferSize) {
            onsetBuffer.removeAt(0)
        }
    }

    private fun estimateBPM(): Pair<Int, Float> {
        if (onsetBuffer.size < framesPerSecond * 2) {
            return Pair(0, 0f)
        }

        // Autocorrelation of onset strength
        val onset = onsetBuffer.toFloatArray()
        val autocorr = FloatArray(onset.size)

        for (lag in 0 until onset.size) {
            var sum = 0f
            for (i in 0 until onset.size - lag) {
                sum += onset[i] * onset[i + lag]
            }
            autocorr[lag] = sum
        }

        // Convert lags to BPM range (60-200)
        val minLag = (framesPerSecond * 60 / 200).toInt()
        val maxLag = (framesPerSecond * 60 / 60).toInt()

        val bpmRange = autocorr.slice(minLag until minOf(maxLag, autocorr.size))
        if (bpmRange.isEmpty()) return Pair(0, 0f)

        val peakIdx = bpmRange.indices.maxByOrNull { bpmRange[it] } ?: return Pair(0, 0f)
        val peakLag = peakIdx + minLag

        val bpm = if (peakLag > 0) ((framesPerSecond * 60) / peakLag).toInt() else 0
        val avgAutocorr = bpmRange.average().toFloat()
        val peakAutocorr = bpmRange[peakIdx]
        val conf = if (avgAutocorr > 0f) {
            (peakAutocorr / avgAutocorr).coerceIn(0f, 1f)
        } else {
            0f
        }

        return Pair(bpm, conf)
    }

    fun getBeatInfo(): BeatInfo {
        val (bpm, conf) = estimateBPM()
        currentBPM = bpm
        confidence = conf

        val beatIntervalMs = if (bpm > 0) (60000f / bpm) else 0f

        return BeatInfo(
            bpm = bpm,
            beatIntervalMs = beatIntervalMs,
            confidence = conf,
            bufferSize = onsetBuffer.size,
            isReady = onsetBuffer.size > (framesPerSecond * 2).toInt()
        )
    }
}

data class BeatInfo(
    val bpm: Int,
    val beatIntervalMs: Float,
    val confidence: Float,
    val bufferSize: Int,
    val isReady: Boolean
)

// ============================================================================
// 2. ONSET DETECTION (Spectral Flux Peak Detection)
// ============================================================================

class OnsetDetector(val nMels: Int = 128, val threshold: Float = 0.3f) {
    /**
     * Real-time Onset Detection (Note/Drum Hit Detection)
     *
     * - Detects exact moments when notes or drums hit
     * - Uses spectral flux (L2 norm of spectrum derivative)
     * - Creates flash effect on beat onsets
     *
     * Latency: ~3ms per frame
     * Size: ~1 KB code
     *
     * Usage:
     *   val onsetDetector = OnsetDetector()
     *   for each mel-spectrogram frame:
     *       val (strength, isOnset) = onsetDetector.detectOnset(melSpectrum)
     *       if (isOnset) {
     *           ledFlashIntensity = strength
     *       }
     */

    private var prevSpectrum: FloatArray? = null
    private val onsetsDetected = mutableListOf<OnsetEvent>()

    fun detectOnset(melSpectrum: FloatArray): Pair<Float, Boolean> {
        // Normalize spectrum
        val maxVal = melSpectrum.maxOrNull() ?: 1f
        val denom = maxVal + 1e-9f
        val spectrum = melSpectrum.map { (it / denom).coerceIn(0f, 1f) }.toFloatArray()

        if (prevSpectrum == null) {
            prevSpectrum = spectrum
            return Pair(0f, false)
        }

        // Spectral flux: L2 norm of positive changes
        val diff = (0 until spectrum.size).map {
            maxOf(spectrum[it] - (prevSpectrum?.get(it) ?: 0f), 0f)
        }.toFloatArray()

        var sumDiff = 0f
        for (v in diff) {
            sumDiff += v * v
        }
        val spectralFlux = sqrt(sumDiff)
        val onsetStrength = spectralFlux.coerceIn(0f, 1f)
        val isOnset = onsetStrength > threshold

        onsetsDetected.add(
            OnsetEvent(
                strength = onsetStrength,
                isOnset = isOnset,
                timestamp = (onsetsDetected.size * 0.02f)  // ~20ms per frame
            )
        )

        if (onsetsDetected.size > 100) {
            onsetsDetected.removeAt(0)
        }

        prevSpectrum = spectrum
        return Pair(onsetStrength, isOnset)
    }

    fun getRecentOnsets(seconds: Int = 5): List<OnsetEvent> {
        val cutoffTime = (onsetsDetected.size * 0.02f) - seconds
        return onsetsDetected.filter { it.timestamp >= cutoffTime }
    }
}

data class OnsetEvent(
    val strength: Float,
    val isOnset: Boolean,
    val timestamp: Float
)

// ============================================================================
// 3. EMOTION RECOGNITION (CNN Multi-class: Happy/Sad/Energetic/Calm)
// ============================================================================

class EmotionRecognizer(private val tfliteInterpreter: Interpreter) {
    /**
     * Music Emotion Recognition using CNN
     *
     * 4 Classes:
     *   0 = Happy (energetic, warm) → YELLOW
     *   1 = Sad (melancholic) → BLUE
     *   2 = Energetic (intense) → RED
     *   3 = Calm (peaceful) → GREEN
     *
     * Latency: ~8ms
     * Size: 36 KB model
     *
     * Usage:
     *   val emotion = emotionRecognizer.predict(melSpectrogram)
     *   when(emotion.classId) {
     *       0 -> ledColor = YELLOW
     *       1 -> ledColor = BLUE
     *       2 -> ledColor = RED
     *       3 -> ledColor = GREEN
     *   }
     */

    private val emotionLabels = listOf("Happy", "Sad", "Energetic", "Calm")
    private val emotionColors = listOf(
        EmotionColor(255, 255, 0),    // Happy → Yellow
        EmotionColor(0, 0, 255),      // Sad → Blue
        EmotionColor(255, 0, 0),      // Energetic → Red
        EmotionColor(0, 255, 0)       // Calm → Green
    )

    fun predict(melSpectrogram: Array<FloatArray>): EmotionPrediction {
        // Quantize input to int8 (match model training)
        val scale = 0.00390625f
        val zeroPoint = -128
        val inputBuffer = ByteBuffer.allocateDirect(1 * 64 * 128 * 1)
            .order(ByteOrder.nativeOrder())

        for (i in 0 until 64) {
            for (j in 0 until 128) {
                val v = melSpectrogram[i][j].coerceIn(0f, 1f)
                val q = ((v / scale) + zeroPoint).toInt().coerceIn(-128, 127)
                inputBuffer.put(q.toByte())
            }
        }
        inputBuffer.rewind()

        val outputBuffer = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        tfliteInterpreter.run(inputBuffer, outputBuffer)

        outputBuffer.rewind()
        val raw = ByteArray(4)
        outputBuffer.get(raw)

        val outScale = 0.00390625f
        val outZeroPoint = -128
        val scores = raw.map { (it.toInt() - outZeroPoint) * outScale }
        val expScores = scores.map { exp(it.toDouble()).toFloat() }
        val sumExp = expScores.sum().coerceAtLeast(1e-6f)
        val probs = expScores.map { (it / sumExp).coerceIn(0f, 1f) }

        val classId = probs.indices.maxByOrNull { probs[it] } ?: 0
        val confidence = probs[classId]

        return EmotionPrediction(
            classId = classId,
            label = emotionLabels[classId],
            confidence = confidence,
            scores = probs,
            color = emotionColors[classId]
        )
    }
}

data class EmotionColor(val r: Int, val g: Int, val b: Int)

data class EmotionPrediction(
    val classId: Int,
    val label: String,
    val confidence: Float,
    val scores: List<Float>,
    val color: EmotionColor
)

// ============================================================================
// INTEGRATED PIPELINE: All 3 Features
// ============================================================================

class AdvancedAudioPipeline(
    private val tfliteInterpreter: Interpreter  // Emotion model interpreter
) {
    private val beatDetector = BeatDetector()
    private val onsetDetector = OnsetDetector()
    private val emotionRecognizer = EmotionRecognizer(tfliteInterpreter)

    data class PipelineOutput(
        val beat: BeatInfo,
        val onset: Pair<Float, Boolean>,
        val emotion: EmotionPrediction,
        val ledCommand: LEDCommand
    )

    fun processFrame(
        melSpectrogram: Array<FloatArray>,
        onsetStrength: Float
    ): PipelineOutput {
        // 1. Beat detection
        beatDetector.addOnsetStrength(onsetStrength)
        val beat = beatDetector.getBeatInfo()

        // 2. Onset detection
        val flattened = melSpectrogram.flatMap { it.toList() }.toFloatArray()
        val (onsetVal, isOnset) = onsetDetector.detectOnset(flattened)

        // 3. Emotion recognition
        val emotion = emotionRecognizer.predict(melSpectrogram)

        // 4. Generate LED command
        val ledCmd = generateLEDCommand(beat, onsetVal, isOnset, emotion)

        return PipelineOutput(beat, Pair(onsetVal, isOnset), emotion, ledCmd)
    }

    private fun generateLEDCommand(
        beat: BeatInfo,
        onsetStrength: Float,
        isOnset: Boolean,
        emotion: EmotionPrediction
    ): LEDCommand {
        val (r, g, b) = emotion.color
        val speed = if (beat.isReady) {
            (beat.beatIntervalMs / 10).toInt().coerceIn(0, 255)
        } else {
            100
        }
        val mode = if (isOnset) 2 else 3  // 2=BLINK, 3=GRADIENT
        val brightness = (onsetStrength * 255).toInt()

        return LEDCommand(
            startByte = 0x01,
            red = r,
            green = g,
            blue = b,
            speed = speed,
            mode = mode,
            brightness = brightness,
            emotion = emotion.label,
            bpm = beat.bpm
        )
    }
}

data class LEDCommand(
    val startByte: Int,
    val red: Int,
    val green: Int,
    val blue: Int,
    val speed: Int,
    val mode: Int,
    val brightness: Int,
    val emotion: String,
    val bpm: Int
) {
    fun toByteArray(): ByteArray = byteArrayOf(
        startByte.toByte(),
        red.toByte(),
        green.toByte(),
        blue.toByte(),
        speed.toByte(),
        mode.toByte(),
        brightness.toByte(),
        0x00
    )
}
