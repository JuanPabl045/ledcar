package com.SmarAudio.ledcar

import android.content.Intent
import android.media.*
import android.media.projection.*
import android.os.Build
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import kotlin.math.*

class MainActivity : FlutterActivity() {

    private val METHOD_CHANNEL  = "com.SmarAudio.ledcar/audio_capture"
    private val EVENT_CHANNEL   = "com.SmarAudio.ledcar/audio_stream"
    private val PROJECTION_CODE = 1001
    private val SAMPLE_RATE     = 16000
    private val YAMNET_SAMPLES  = 15600          // YAMNet needs exactly this at 16kHz
    private val SECTION_AUDIO   = 70656          // ~4.4s at 16kHz → resample to 22050 → 96 mel frames
    private val FAST_CHUNK      = 533            // ~33ms chunks for ~30 fast energy updates/sec
    private val FFT_SIZE         = 1024           // next power-of-2 for radix-2 FFT
    private val SECTION_SR      = 22050          // Section model trained at 22050Hz

    private var mediaProjection: MediaProjection?       = null
    private var audioRecord:     AudioRecord?            = null
    private var yamnetInterpreter: Interpreter?          = null
    private var sectionInterpreter: Interpreter?         = null
    private var emotionInterpreter: Interpreter?          = null
    private var advancedPipeline: AdvancedAudioPipeline?  = null
    private var eventSink:       EventChannel.EventSink? = null
    private var captureThread:   Thread?                 = null
    private var isCapturing      = false
    private var frameCounter     = 0
    private var pendingProjectionResult: Intent? = null
    private val pendingResults = ArrayDeque<Map<String, Any>>()
    private val MAX_PENDING = 5
    private var previousSpectrum: Array<FloatArray>? = null

    // ── Mel-spectrogram parameters (must match training config!) ──
    private val N_FFT       = 2048
    private val HOP_LENGTH  = 1024
    private val N_MELS      = 80
    private val N_FRAMES    = 96
    private val MEL_FMIN    = 0f
    private val MEL_FMAX    = 11025f   // SECTION_SR / 2
    private lateinit var hannWindow: FloatArray
    private lateinit var melFilterbank: Array<FloatArray>

    // Section labels (2 classes: non_chorus / chorus)
    private val SECTION_LABELS = arrayOf("non_chorus", "chorus")

    // Mapeo directo: indice YAMNet -> nombre de clase (solo las relevantes)
    private val labelNames = mapOf(
        24 to "Singing", 25 to "Choir", 31 to "Rapping",
        132 to "Music", 133 to "Musical instrument",
        135 to "Guitar", 136 to "Electric guitar", 137 to "Bass guitar",
        138 to "Acoustic guitar", 147 to "Keyboard", 148 to "Piano",
        153 to "Synthesizer", 157 to "Drum kit", 158 to "Drum machine",
        159 to "Drum", 160 to "Snare drum", 163 to "Bass drum",
        166 to "Cymbal", 179 to "Orchestra", 182 to "Trumpet",
        186 to "Violin", 192 to "Saxophone",
        211 to "Pop music", 212 to "Hip hop music", 213 to "Beatboxing",
        214 to "Rock music", 216 to "Punk rock",
        221 to "R&B", 222 to "Soul music", 223 to "Reggae",
        227 to "Funk", 230 to "Jazz", 231 to "Disco",
        232 to "Classical music", 234 to "Electronic music",
        235 to "House music", 236 to "Techno", 237 to "Dubstep",
        241 to "Ambient music", 246 to "Blues", 249 to "Vocal music",
        269 to "Dance music"
    )

    // Mapeo: indice YAMNet -> categoria musical
    private val indexToCategory = mapOf(
        // rock
        214 to "rock", 216 to "rock", 136 to "rock", 137 to "rock",
        // electronic
        234 to "electronic", 235 to "electronic", 236 to "electronic",
        237 to "electronic", 153 to "electronic", 240 to "electronic",
        269 to "electronic",
        // hiphop
        212 to "hiphop", 31 to "hiphop", 213 to "hiphop", 158 to "hiphop",
        // jazz
        230 to "jazz", 192 to "jazz", 182 to "jazz",
        // classical
        232 to "classical", 179 to "classical", 186 to "classical", 148 to "classical",
        // pop
        211 to "pop", 24 to "pop", 249 to "pop",
        // ambient
        241 to "ambient",
        // reggae
        223 to "reggae",
        // blues / soul / funk
        246 to "blues", 222 to "blues", 221 to "blues", 227 to "blues",
        // disco
        231 to "pop",
    )

    // Mapeo: indice YAMNet -> instrumento dominante
    private val indexToInstrument = mapOf(
        // vocals
        24 to "vocals", 25 to "vocals", 31 to "vocals",
        249 to "vocals", 213 to "vocals",
        // drums
        157 to "drums", 158 to "drums", 159 to "drums",
        160 to "drums", 163 to "drums", 166 to "drums",
        // bass
        137 to "bass",
        // melodic (guitar, keys, strings, brass, synth)
        135 to "melodic", 136 to "melodic", 138 to "melodic",
        147 to "melodic", 148 to "melodic", 153 to "melodic",
        182 to "melodic", 186 to "melodic", 192 to "melodic",
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCapture" -> {
                        android.util.Log.d("AudioCapture", "startCapture llamado, isCapturing=$isCapturing")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            if (isCapturing) {
                                android.util.Log.d("AudioCapture", "ya capturando — reconectando event sink")
                                result.success(true)
                            } else {
                                // Responder a Dart ANTES de lanzar el dialogo del sistema,
                                // para que invokeMethod no quede colgado si startActivityForResult falla.
                                result.success(true)
                                try {
                                    loadModels()
                                    requestMediaProjection()
                                } catch (e: Throwable) {
                                    android.util.Log.e("AudioCapture", "error en requestMediaProjection: ${e.message}")
                                }
                            }
                        } else result.success(false)
                    }
                    "isCapturing" -> {
                        result.success(isCapturing)
                    }
                    "stopCapture" -> { stopCapture(); result.success(null) }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                    android.util.Log.d("AudioCapture", "eventSink conectado: ${sink != null}, isCapturing=$isCapturing")
                    // Drenar cola de resultados pendientes
                    runOnUiThread {
                        while (pendingResults.isNotEmpty() && eventSink != null) {
                            eventSink?.success(pendingResults.removeFirst())
                        }
                    }
                }
                override fun onCancel(args: Any?) {
                    eventSink = null
                    pendingResults.clear()
                    android.util.Log.d("AudioCapture", "eventSink desconectado (onCancel)")
                }
            })
    }

    private fun loadModels() {
        // YAMNet desactivado

        // Section detector (calm vs energetic)
        if (sectionInterpreter == null) {
            try {
                val afd = assets.openFd("section_detector.tflite")
                val stream = FileInputStream(afd.fileDescriptor)
                val buffer: MappedByteBuffer = stream.channel.map(
                    FileChannel.MapMode.READ_ONLY, afd.startOffset, afd.declaredLength)
                sectionInterpreter = Interpreter(buffer)
                initMelSpectrogram()
                android.util.Log.d("Section", "Modelo de secciones cargado")
            } catch (e: Exception) {
                android.util.Log.e("Section", "Error cargando modelo: ${e.message}")
            }
        }

        // Emotion model + advanced pipeline
        if (emotionInterpreter == null) {
            try {
                val afd = assets.openFd("modelo_emotion_optimized.tflite")
                val stream = FileInputStream(afd.fileDescriptor)
                val buffer: MappedByteBuffer = stream.channel.map(
                    FileChannel.MapMode.READ_ONLY, afd.startOffset, afd.declaredLength)
                emotionInterpreter = Interpreter(buffer)
                advancedPipeline = AdvancedAudioPipeline(emotionInterpreter!!)
                android.util.Log.d("Emotion", "Modelo de emocion cargado correctamente")
                android.util.Log.d("Pipeline", "Advanced pipeline inicializado")
            } catch (e: Exception) {
                android.util.Log.e("Emotion", "Error cargando modelo: ${e.message}")
            }
        }
    }

    // ── Mel-spectrogram initialization ──

    private fun initMelSpectrogram() {
        hannWindow = FloatArray(N_FFT) { (0.5 * (1.0 - cos(2.0 * PI * it / (N_FFT - 1)))).toFloat() }
        melFilterbank = createMelFilterbank()
    }

    private fun hzToMel(hz: Float): Float = 2595f * log10(1f + hz / 700f)
    private fun melToHz(mel: Float): Float = 700f * (10f.pow(mel / 2595f) - 1f)

    private fun createMelFilterbank(): Array<FloatArray> {
        val nFreqs = N_FFT / 2 + 1
        val melMin = hzToMel(MEL_FMIN)
        val melMax = hzToMel(MEL_FMAX)
        val melPoints = FloatArray(N_MELS + 2) { melMin + it * (melMax - melMin) / (N_MELS + 1) }
        val hzPoints = FloatArray(N_MELS + 2) { melToHz(melPoints[it]) }
        val bins = IntArray(N_MELS + 2) { ((N_FFT + 1).toFloat() * hzPoints[it] / SECTION_SR).toInt() }

        return Array(N_MELS) { m ->
            FloatArray(nFreqs) { k ->
                when {
                    k < bins[m] -> 0f
                    k <= bins[m + 1] && bins[m + 1] > bins[m] ->
                        (k - bins[m]).toFloat() / (bins[m + 1] - bins[m])
                    k <= bins[m + 2] && bins[m + 2] > bins[m + 1] ->
                        (bins[m + 2] - k).toFloat() / (bins[m + 2] - bins[m + 1])
                    else -> 0f
                }
            }
        }
    }

    // ── Radix-2 Cooley-Tukey FFT (in-place) ──

    private fun fft(real: FloatArray, imag: FloatArray) {
        val n = real.size
        var j = 0
        for (i in 0 until n - 1) {
            if (i < j) {
                var t = real[i]; real[i] = real[j]; real[j] = t
                t = imag[i]; imag[i] = imag[j]; imag[j] = t
            }
            var k = n / 2
            while (k <= j) { j -= k; k /= 2 }
            j += k
        }
        var step = 1
        while (step < n) {
            val angle = -PI / step
            val wR = cos(angle).toFloat()
            val wI = sin(angle).toFloat()
            var wr = 1f; var wi = 0f
            for (m in 0 until step) {
                var i = m
                while (i < n) {
                    val j2 = i + step
                    val tR = wr * real[j2] - wi * imag[j2]
                    val tI = wr * imag[j2] + wi * real[j2]
                    real[j2] = real[i] - tR
                    imag[j2] = imag[i] - tI
                    real[i] += tR
                    imag[i] += tI
                    i += step * 2
                }
                val newWr = wr * wR - wi * wI
                wi = wr * wI + wi * wR
                wr = newWr
            }
            step *= 2
        }
    }

    private fun computeMelSpectrogram(audio: FloatArray): Array<FloatArray> {
        // Center-pad audio (like librosa center=True)
        val pad = N_FFT / 2
        val padded = FloatArray(audio.size + 2 * pad)
        System.arraycopy(audio, 0, padded, pad, audio.size)

        val nFreqs = N_FFT / 2 + 1
        val nFrames = minOf((padded.size - N_FFT) / HOP_LENGTH + 1, N_FRAMES)
        val spec = Array(N_MELS) { FloatArray(N_FRAMES) }

        val fftReal = FloatArray(N_FFT)
        val fftImag = FloatArray(N_FFT)

        for (t in 0 until nFrames) {
            val start = t * HOP_LENGTH
            // Windowing
            for (i in 0 until N_FFT) {
                fftReal[i] = if (start + i < padded.size) padded[start + i] * hannWindow[i] else 0f
                fftImag[i] = 0f
            }
            fft(fftReal, fftImag)

            // Power spectrum → mel filterbank → dB
            for (m in 0 until N_MELS) {
                var sum = 0f
                for (k in 0 until nFreqs) {
                    val mag2 = fftReal[k] * fftReal[k] + fftImag[k] * fftImag[k]
                    sum += melFilterbank[m][k] * mag2
                }
                spec[m][t] = 10f * log10(maxOf(sum, 1e-10f))
            }
        }

        // Normalize: power_to_db(ref=max) → values in [-80, 0] range
        // Matches librosa.power_to_db(S, ref=np.max) used in training
        var maxVal = -Float.MAX_VALUE
        for (m in spec.indices) for (t in spec[m].indices) {
            if (spec[m][t] > maxVal) maxVal = spec[m][t]
        }
        for (m in spec.indices) for (t in spec[m].indices) {
            spec[m][t] = spec[m][t] - maxVal  // shift so max = 0
            if (spec[m][t] < -80f) spec[m][t] = -80f // floor at -80 dB
        }

        return spec
    }

    private fun normalizeMelToUnit(mel: Array<FloatArray>): Array<FloatArray> {
        val out = Array(mel.size) { FloatArray(mel[0].size) }
        for (m in mel.indices) {
            for (t in mel[m].indices) {
                out[m][t] = ((mel[m][t] + 80f) / 80f).coerceIn(0f, 1f)
            }
        }
        return out
    }

    private fun resizeMelSpec(
        mel: Array<FloatArray>,
        targetMels: Int,
        targetFrames: Int
    ): Array<FloatArray> {
        val srcMels = mel.size
        val srcFrames = mel[0].size
        val out = Array(targetMels) { FloatArray(targetFrames) }
        for (y in 0 until targetMels) {
            val srcY = if (targetMels == 1) 0f else y * (srcMels - 1).toFloat() / (targetMels - 1)
            val y0 = srcY.toInt().coerceIn(0, srcMels - 1)
            val y1 = (y0 + 1).coerceIn(0, srcMels - 1)
            val ly = srcY - y0
            for (x in 0 until targetFrames) {
                val srcX = if (targetFrames == 1) 0f else x * (srcFrames - 1).toFloat() / (targetFrames - 1)
                val x0 = srcX.toInt().coerceIn(0, srcFrames - 1)
                val x1 = (x0 + 1).coerceIn(0, srcFrames - 1)
                val lx = srcX - x0
                val v00 = mel[y0][x0]
                val v01 = mel[y0][x1]
                val v10 = mel[y1][x0]
                val v11 = mel[y1][x1]
                val v0 = v00 + (v01 - v00) * lx
                val v1 = v10 + (v11 - v10) * lx
                out[y][x] = v0 + (v1 - v0) * ly
            }
        }
        return out
    }

    private fun computeSpectralFlux(mel: Array<FloatArray>): Float {
        if (mel.isEmpty()) return 0f
        if (previousSpectrum == null) {
            previousSpectrum = mel.map { it.clone() }.toTypedArray()
            return 0f
        }

        var sumDiff = 0f
        for (i in mel.indices) {
            for (j in mel[i].indices) {
                val diff = maxOf(mel[i][j] - (previousSpectrum?.get(i)?.get(j) ?: 0f), 0f)
                sumDiff += diff * diff
            }
        }
        previousSpectrum = mel.map { it.clone() }.toTypedArray()
        val norm = sqrt(sumDiff / (mel.size * mel[0].size).toFloat()).coerceIn(0f, 1f)
        return norm
    }

    private fun runSectionInferenceFromMel(mel: Array<FloatArray>, energy: Double): Map<String, Any> {
        if (sectionInterpreter == null) {
            return mapOf("section" to "non_chorus", "sectionConfidence" to 0.0, "energy" to energy)
        }

        return try {
            // Float32 model: input [1, 80, 96, 1], output [1, 2]
            val input = Array(1) { Array(N_MELS) { m -> Array(N_FRAMES) { t -> floatArrayOf(mel[m][t]) } } }
            val output = Array(1) { FloatArray(2) }
            sectionInterpreter!!.run(input, output)

            val scores = output[0]
            val bestIdx = if (scores[1] > scores[0]) 1 else 0
            mapOf(
                "section" to SECTION_LABELS[bestIdx],
                "sectionConfidence" to scores[bestIdx].toDouble().coerceIn(0.0, 1.0),
                "energy" to energy
            )
        } catch (e: Exception) {
            android.util.Log.e("Section", "Inference error: ${e.message}")
            mapOf("section" to "non_chorus", "sectionConfidence" to 0.0, "energy" to energy)
        }
    }

    private fun requestMediaProjection() {
        // Arrancar foreground service ANTES de pedir permiso
        val serviceIntent = Intent(this, MediaProjectionService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(mgr.createScreenCaptureIntent(), PROJECTION_CODE)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun onActivityResult(req: Int, res: Int, data: Intent?) {
        super.onActivityResult(req, res, data)
        if (req == PROJECTION_CODE && res == RESULT_OK && data != null) {
            val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            mediaProjection = mgr.getMediaProjection(res, data)
            if (!isFinishing && !isDestroyed) {
                android.util.Log.d("AudioCapture", "onActivityResult: intentando startCapture directo")
                startCapture()
            } else {
                android.util.Log.d("AudioCapture", "onActivityResult: Activity stopped, deferring to onResume")
                pendingProjectionResult = data
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (pendingProjectionResult != null && !isCapturing && mediaProjection != null) {
            android.util.Log.d("AudioCapture", "onResume: arrancando captura diferida")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startCapture()
            }
            pendingProjectionResult = null
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun startCapture() {
        val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection!!)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .build()

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()

        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)

        audioRecord = AudioRecord.Builder()
            .setAudioPlaybackCaptureConfig(config)
            .setAudioFormat(format)
            .setBufferSizeInBytes(minBuf * 4)
            .build()

        audioRecord?.startRecording()
        frameCounter = 0

        captureThread = Thread {
            isCapturing = true
            android.util.Log.d("AudioCapture", "Hilo de captura iniciado, isCapturing=$isCapturing")
          try {
            // Ring buffer accumulates small chunks into full model buffer
            val ringBuffer = FloatArray(SECTION_AUDIO)
            var ringPos = 0
            val fastChunk = FloatArray(FAST_CHUNK)
            var yamnetSampleCount = 0  // separate counter for YAMNet (~3s cadence)

            // Cached model results (persist between fast updates)
            var lastSection = "non_chorus"
            var lastSectionConf = 0.0
            var lastCategory = ""
            var lastConfidence = 0.0
            var lastTopClass = ""
            var lastInstrument = "mixed"
            var lastBeatBpm = 0
            var lastBeatConfidence = 0.0
            var lastBeatIntervalMs = 0.0
            var lastOnsetStrength = 0.0
            var lastIsOnset = false
            var lastEmotionLabel = ""
            var lastEmotionConfidence = 0.0
            var lastEmotionR = 0
            var lastEmotionG = 0
            var lastEmotionB = 0

            // EMA smoothing for energy/bass (avoids jumpy values)
            var smoothEnergy = 0.0
            var smoothBass = 0.0
            val EMA_FAST = 0.6   // higher = more responsive, lower = smoother

            // FFT reusable buffers for fast-path band analysis (must be power of 2)
            val fftR = FloatArray(FFT_SIZE)
            val fftI = FloatArray(FFT_SIZE)
            // Hann window for the read chunk (FAST_CHUNK samples)
            val fastHann = FloatArray(FAST_CHUNK) {
                (0.5 * (1.0 - cos(2.0 * PI * it / (FAST_CHUNK - 1)))).toFloat()
            }

            // Frequency band bins (at 16kHz, 1024 FFT → bin = 15.625 Hz)
            // Sub-bass/kick: 20-100Hz → bins 1-6
            // Bass: 100-250Hz → bins 7-16
            // Snare body: 250-500Hz → bins 16-32
            // Hi-hat/snare crack: 3000-6000Hz → bins 192-384
            val KICK_LO = 1;  val KICK_HI = 6
            val BASS_LO = 7;  val BASS_HI = 16
            val SNARE_LO = 16; val SNARE_HI = 32
            val HAT_LO = 192; val HAT_HI = 384

            // Transient detection: running averages for each band
            var avgKick = 0.0;  var avgSnare = 0.0
            val TRANSIENT_DECAY = 0.82       // slightly shorter memory -> more drum responsiveness
            val KICK_THRESHOLD = 1.32         // a bit easier to trigger kick hits
            val SNARE_THRESHOLD = 1.22        // a bit easier to trigger snare hits

            while (isCapturing) {
                // ── FAST PATH: read 125ms chunk ──
                val read = audioRecord?.read(
                    fastChunk, 0, FAST_CHUNK, AudioRecord.READ_BLOCKING) ?: 0
                if (read <= 0) continue

                // Compute fast RMS energy from this small chunk
                var sumSq = 0.0
                for (i in 0 until read) {
                    sumSq += fastChunk[i] * fastChunk[i]
                }
                val energy = sqrt(sumSq / read).coerceIn(0.0, 1.0)

                // ── FFT-based frequency band analysis (real-time) ──
                for (i in 0 until FFT_SIZE) {
                    fftR[i] = if (i < read) fastChunk[i] * fastHann[i] else 0f
                    fftI[i] = 0f
                }
                fft(fftR, fftI)

                // Extract energy per band
                fun bandEnergy(lo: Int, hi: Int): Double {
                    var s = 0.0
                    for (k in lo..minOf(hi, FFT_SIZE / 2)) {
                        s += fftR[k] * fftR[k] + fftI[k] * fftI[k]
                    }
                    return sqrt(s / (hi - lo + 1))
                }

                val kickE  = bandEnergy(KICK_LO, KICK_HI)
                val bassE  = bandEnergy(BASS_LO, BASS_HI)
                val snareE = bandEnergy(SNARE_LO, SNARE_HI)
                val hatE   = bandEnergy(HAT_LO, HAT_HI)

                // Combined bass energy (kick + bass bands, normalized)
                // ×1.5 instead of ×3 so it doesn't saturate — preserves dynamic range
                val bassEnergy = ((kickE + bassE) * 1.5).coerceIn(0.0, 1.0)

                // ── Transient (hit) detection ──
                // Compare current frame vs running average → spike = hit
                avgKick  = avgKick * TRANSIENT_DECAY + kickE * (1 - TRANSIENT_DECAY)
                avgSnare = avgSnare * TRANSIENT_DECAY + snareE * (1 - TRANSIENT_DECAY)

                val kickHit  = avgKick > 0.001 && kickE / avgKick > KICK_THRESHOLD
                val snareHit = avgSnare > 0.001 && snareE / avgSnare > SNARE_THRESHOLD

                // EMA smooth
                smoothEnergy = smoothEnergy + EMA_FAST * (energy - smoothEnergy)
                smoothBass = smoothBass + EMA_FAST * (bassEnergy.toDouble() - smoothBass)

                // Send FAST energy update to Flutter (~15 times/sec)
                val fastResult = mutableMapOf<String, Any>(
                    "energy" to smoothEnergy,
                    "bassEnergy" to smoothBass,
                    "kickHit" to kickHit,
                    "snareHit" to snareHit,
                    "kickEnergy" to kickE.coerceIn(0.0, 1.0),
                    "section" to lastSection,
                    "sectionConfidence" to lastSectionConf,
                    "isFastUpdate" to true,
                    "beatBpm" to lastBeatBpm,
                    "beatConfidence" to lastBeatConfidence,
                    "beatIntervalMs" to lastBeatIntervalMs,
                    "onsetStrength" to lastOnsetStrength,
                    "isOnset" to lastIsOnset,
                    "emotionLabel" to lastEmotionLabel,
                    "emotionConfidence" to lastEmotionConfidence,
                    "emotionR" to lastEmotionR,
                    "emotionG" to lastEmotionG,
                    "emotionB" to lastEmotionB,
                )
                if (lastCategory.isNotEmpty()) {
                    fastResult["category"] = lastCategory
                    fastResult["confidence"] = lastConfidence
                    fastResult["topClass"] = lastTopClass
                }
                fastResult["instrument"] = lastInstrument
                runOnUiThread {
                    val sink = eventSink
                    if (sink != null) {
                        while (pendingResults.isNotEmpty()) {
                            sink.success(pendingResults.removeFirst())
                        }
                        sink.success(fastResult)
                    } else if (pendingResults.size < MAX_PENDING) {
                        pendingResults.addLast(fastResult)
                    }
                }

                // ── SLOW PATH: accumulate into ring buffer ──
                val toCopy = minOf(read, SECTION_AUDIO - ringPos)
                System.arraycopy(fastChunk, 0, ringBuffer, ringPos, toCopy)
                ringPos += toCopy
                yamnetSampleCount += read

                // YAMNet every ~3s (48000 samples at 16kHz), independently of section model
                // YAMNet desactivado

                // Section model when ring buffer full (~4.4s of audio)
                if (ringPos >= SECTION_AUDIO) {
                    val modelAudio = ringBuffer.copyOf()
                    ringPos = 0
                    frameCounter++

                    val energy = sqrt(modelAudio.map { (it * it).toDouble() }.average()).coerceIn(0.0, 1.0)
                    val audio22k = resample(modelAudio, SAMPLE_RATE, SECTION_SR)
                    val mel = computeMelSpectrogram(audio22k)

                    // Section detector: resample 16k→22k + mel + inference
                    val sectionResult = runSectionInferenceFromMel(mel, energy)
                    lastSection = sectionResult["section"] as String
                    lastSectionConf = sectionResult["sectionConfidence"] as Double

                    // Advanced pipeline: beat/onset/emotion
                    val melNorm = normalizeMelToUnit(mel)
                    val melResized = resizeMelSpec(melNorm, 64, 128)
                    val onsetStrength = computeSpectralFlux(melResized)
                    try {
                        val pipeline = advancedPipeline
                        if (pipeline != null) {
                            val out = pipeline.processFrame(melResized, onsetStrength)
                            lastBeatBpm = out.beat.bpm
                            lastBeatConfidence = out.beat.confidence.toDouble()
                            lastBeatIntervalMs = out.beat.beatIntervalMs.toDouble()
                            lastOnsetStrength = out.onset.first.toDouble()
                            lastIsOnset = out.onset.second
                            lastEmotionLabel = out.emotion.label
                            lastEmotionConfidence = out.emotion.confidence.toDouble()
                            lastEmotionR = out.emotion.color.r
                            lastEmotionG = out.emotion.color.g
                            lastEmotionB = out.emotion.color.b
                        }
                    } catch (e: Exception) {
                        android.util.Log.e("Pipeline", "Advanced pipeline error: ${e.message}")
                    }

                    // Send full model update
                    val fullResult = mutableMapOf<String, Any>(
                        "energy" to (sectionResult["energy"] as Double),
                        "bassEnergy" to bassEnergy,
                        "section" to lastSection,
                        "sectionConfidence" to lastSectionConf,
                        "isFastUpdate" to false,
                        "beatBpm" to lastBeatBpm,
                        "beatConfidence" to lastBeatConfidence,
                        "beatIntervalMs" to lastBeatIntervalMs,
                        "onsetStrength" to lastOnsetStrength,
                        "isOnset" to lastIsOnset,
                        "emotionLabel" to lastEmotionLabel,
                        "emotionConfidence" to lastEmotionConfidence,
                        "emotionR" to lastEmotionR,
                        "emotionG" to lastEmotionG,
                        "emotionB" to lastEmotionB,
                    )
                    if (lastCategory.isNotEmpty()) {
                        fullResult["category"] = lastCategory
                        fullResult["confidence"] = lastConfidence
                        fullResult["topClass"] = lastTopClass
                    }
                    fullResult["instrument"] = lastInstrument
                    runOnUiThread {
                        val sink = eventSink
                        if (sink != null) {
                            while (pendingResults.isNotEmpty()) {
                                sink.success(pendingResults.removeFirst())
                            }
                            sink.success(fullResult)
                        } else if (pendingResults.size < MAX_PENDING) {
                            pendingResults.addLast(fullResult)
                        }
                    }
                }
            }
          } catch (e: Exception) {
              android.util.Log.e("AudioCapture", "Thread crasheó: ${e.message}", e)
              isCapturing = false
          }
        }.also { it.start() }
    }

    // ── Resample audio (linear interpolation) ──
    private fun resample(input: FloatArray, srcRate: Int, dstRate: Int): FloatArray {
        if (srcRate == dstRate) return input
        val ratio = srcRate.toDouble() / dstRate.toDouble()
        val outLen = (input.size.toLong() * dstRate / srcRate).toInt()
        val output = FloatArray(outLen)
        for (i in 0 until outLen) {
            val srcIdx = i * ratio
            val idx0 = srcIdx.toInt().coerceAtMost(input.size - 1)
            val idx1 = (idx0 + 1).coerceAtMost(input.size - 1)
            val frac = (srcIdx - idx0).toFloat()
            output[i] = input[idx0] + frac * (input[idx1] - input[idx0])
        }
        return output
    }

    private fun runSectionInference(audio16k: FloatArray): Map<String, Any> {
        val energy = sqrt(audio16k.map { (it * it).toDouble() }.average()).coerceIn(0.0, 1.0)

        if (sectionInterpreter == null) {
            return mapOf("section" to "non_chorus", "sectionConfidence" to 0.0, "energy" to energy)
        }

        try {
            // Resample 16kHz → 22050Hz (must match training sample rate)
            val audio22k = resample(audio16k, SAMPLE_RATE, SECTION_SR)
            val mel = computeMelSpectrogram(audio22k)
            return runSectionInferenceFromMel(mel, energy)
        } catch (e: Exception) {
            android.util.Log.e("Section", "Inference error: ${e.message}")
            return mapOf("section" to "non_chorus", "sectionConfidence" to 0.0, "energy" to energy)
        }
    }

    private fun runYamnetInference(audio: FloatArray): Map<String, Any> {
        val input   = Array(1) { audio }
        val scores  = Array(1) { FloatArray(521) }

        try {
            yamnetInterpreter?.run(input, scores)
        } catch (e: Exception) {
            android.util.Log.e("YAMNet", "Inference error: ${e.message}")
            return mapOf("category" to "default", "confidence" to 0.0, "topClass" to "unknown")
        }

        val s = scores[0]

        var topIdx = 0
        var topScore = 0f
        for (i in s.indices) {
            if (s[i] > topScore) { topScore = s[i]; topIdx = i }
        }

        val catScores = mutableMapOf<String, Float>()
        for ((idx, cat) in indexToCategory) {
            if (idx < s.size) {
                catScores[cat] = (catScores[cat] ?: 0f) + s[idx]
            }
        }
        val bestCat = catScores.maxByOrNull { it.value }
        val category = if (bestCat != null && bestCat.value > 0.05f) bestCat.key else "default"
        val topName = labelNames[topIdx] ?: "class_$topIdx"

        // Instrumento dominante
        val instScores = mutableMapOf<String, Float>()
        for ((idx, inst) in indexToInstrument) {
            if (idx < s.size) {
                instScores[inst] = (instScores[inst] ?: 0f) + s[idx]
            }
        }
        val bestInst = instScores.maxByOrNull { it.value }
        val instrument = if (bestInst != null && bestInst.value > 0.03f) bestInst.key else "mixed"

        return mapOf(
            "category"   to category,
            "confidence" to topScore.toDouble(),
            "topClass"   to topName,
            "instrument" to instrument
        )
    }

    private fun stopCapture() {
        isCapturing = false
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord   = null
        mediaProjection?.stop()
        mediaProjection = null
        yamnetInterpreter?.close()
        yamnetInterpreter = null
        sectionInterpreter?.close()
        sectionInterpreter = null
        emotionInterpreter?.close()
        emotionInterpreter = null
        advancedPipeline = null
        // Detener foreground service
        stopService(Intent(this, MediaProjectionService::class.java))
    }
}