import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AudioAnalysisResult {
  final String category;
  final double confidence;
  final String topClass;
  final double energy;
  final double bassEnergy;
  final double kickEnergy;
  final bool kickHit; // transient detected in kick band
  final bool snareHit; // transient detected in snare band
  final String section; // "calm" or "energetic"
  final double sectionConfidence; // 0.0 - 1.0
  final bool isFastUpdate; // true = energy-only, false = full model
  final String instrument; // "vocals", "drums", "bass", "melodic", "mixed"
  final int beatBpm;
  final double beatConfidence;
  final double beatIntervalMs;
  final double onsetStrength;
  final bool isOnset;
  final String emotionLabel;
  final double emotionConfidence;
  final int emotionR;
  final int emotionG;
  final int emotionB;

  AudioAnalysisResult({
    required this.category,
    required this.confidence,
    required this.topClass,
    required this.energy,
    required this.bassEnergy,
    required this.kickEnergy,
    required this.kickHit,
    required this.snareHit,
    required this.section,
    required this.sectionConfidence,
    required this.isFastUpdate,
    required this.instrument,
    required this.beatBpm,
    required this.beatConfidence,
    required this.beatIntervalMs,
    required this.onsetStrength,
    required this.isOnset,
    required this.emotionLabel,
    required this.emotionConfidence,
    required this.emotionR,
    required this.emotionG,
    required this.emotionB,
  });

  factory AudioAnalysisResult.fromMap(Map map) => AudioAnalysisResult(
    category: map['category'] as String? ?? '',
    confidence: (map['confidence'] as num?)?.toDouble() ?? 0.0,
    topClass: map['topClass'] as String? ?? '',
    energy: (map['energy'] as num?)?.toDouble() ?? 0.0,
    bassEnergy: (map['bassEnergy'] as num?)?.toDouble() ?? 0.0,
    kickEnergy: (map['kickEnergy'] as num?)?.toDouble() ?? 0.0,
    kickHit: map['kickHit'] as bool? ?? false,
    snareHit: map['snareHit'] as bool? ?? false,
    section: map['section'] as String? ?? 'calm',
    sectionConfidence: (map['sectionConfidence'] as num?)?.toDouble() ?? 0.0,
    isFastUpdate: map['isFastUpdate'] as bool? ?? true,
    instrument: map['instrument'] as String? ?? 'mixed',
    beatBpm: (map['beatBpm'] as num?)?.toInt() ?? 0,
    beatConfidence: (map['beatConfidence'] as num?)?.toDouble() ?? 0.0,
    beatIntervalMs: (map['beatIntervalMs'] as num?)?.toDouble() ?? 0.0,
    onsetStrength: (map['onsetStrength'] as num?)?.toDouble() ?? 0.0,
    isOnset: map['isOnset'] as bool? ?? false,
    emotionLabel: map['emotionLabel'] as String? ?? '',
    emotionConfidence: (map['emotionConfidence'] as num?)?.toDouble() ?? 0.0,
    emotionR: (map['emotionR'] as num?)?.toInt() ?? 0,
    emotionG: (map['emotionG'] as num?)?.toInt() ?? 0,
    emotionB: (map['emotionB'] as num?)?.toInt() ?? 0,
  );

  bool get hasGenre => category.isNotEmpty;
}

class AudioCaptureService {
  static const _channel = MethodChannel('com.SmarAudio.ledcar/audio_capture');
  static const _eventChannel = EventChannel(
    'com.SmarAudio.ledcar/audio_stream',
  );

  StreamSubscription? _audioSub;
  final void Function(AudioAnalysisResult result) onResult;

  AudioCaptureService({required this.onResult});

  /// Pregunta a Kotlin si el hilo de captura ya esta corriendo.
  Future<bool> isAlreadyCapturing() async {
    try {
      final result = await _channel.invokeMethod<bool>('isCapturing');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestPermissionAndStart() async {
    try {
      final granted = await _channel.invokeMethod<bool>('startCapture');
      if (granted != true) return false;
      _startListening();
      return true;
    } catch (e) {
      debugPrint('AudioCapture error: $e');
      return false;
    }
  }

  /// Reconecta al EventChannel sin volver a llamar startCapture.
  /// Usar cuando Kotlin ya está capturando pero el stream se perdió.
  void reconnectListener() {
    debugPrint('AudioCapture: reconectando listener al EventChannel');
    _audioSub?.cancel();
    _startListening();
  }

  void _startListening() {
    _audioSub?.cancel();
    _audioSub = _eventChannel.receiveBroadcastStream().listen(
      (data) {
        if (data is Map) {
          onResult(AudioAnalysisResult.fromMap(data));
        }
      },
      onError: (e) {
        debugPrint('AudioCapture stream error: $e');
      },
    );
    debugPrint('AudioCapture: listener activo');
  }

  void stop() {
    _audioSub?.cancel();
    _audioSub = null;
    _channel.invokeMethod('stopCapture');
  }

  void dispose() => stop();
}
