import 'dart:async';
import 'package:flutter/material.dart';
import '../services/spotify_api.dart';
import 'reaction_engine.dart';

class BeatScheduler {
  List<Beat> _beats = [];
  int _nextBeatIdx = 0;
  int _latencyMs = 40;
  Timer? _timer;
  Timer? _syntheticTimer;
  (int, int, int) _activeColor = (255, 255, 255);

  final void Function(LedCommand) onCommand;
  BeatScheduler({required this.onCommand});

  void setLatency(int ms) {
    _latencyMs = ms;
    debugPrint('BLE latency: ${ms}ms');
  }

  void setColor((int, int, int) color) => _activeColor = color;

  // Modo con audio_analysis (futuro)
  void loadAnalysis(TrackAnalysis analysis, double energy, double valence) {
    _beats = analysis.beats;
    _nextBeatIdx = 0;
    _activeColor = ReactionEngine.baseColor(energy, valence);
    onCommand(ReactionEngine.fromEnergy(energy));
  }

  // Modo sintetico por BPM estimado
  void startSynthetic(int bpm, (int, int, int) color) {
    _syntheticTimer?.cancel();
    _activeColor = color;
    final intervalMs = ReactionEngine.beatIntervalMs(bpm);
    debugPrint('Beat sintetico: ${bpm}BPM cada ${intervalMs}ms');

    _syntheticTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      final cmd = LedCommand(
        tipo: 0x01,
        r: _activeColor.$1,
        g: _activeColor.$2,
        b: _activeColor.$3,
        brillo: 255,
        patron: 3,
        offsetMs: _latencyMs,
      );
      onCommand(cmd);
    });
  }

  void seekTo(int playheadMs) {
    _nextBeatIdx = _beats.indexWhere((b) => (b.start * 1000) >= playheadMs);
    if (_nextBeatIdx < 0) _nextBeatIdx = _beats.length;
  }

  // Modo con audio_analysis
  void start(int Function() getPlayheadMs) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (_nextBeatIdx >= _beats.length) return;
      final nowMs = getPlayheadMs();
      final beat = _beats[_nextBeatIdx];
      final beatMs = (beat.start * 1000).toInt();
      final timeLeft = beatMs - nowMs;
      if (timeLeft <= _latencyMs + 5) {
        final offset = (timeLeft - _latencyMs).clamp(0, 500).toInt();
        final cmd = LedCommand(
          tipo: 0x01,
          r: _activeColor.$1,
          g: _activeColor.$2,
          b: _activeColor.$3,
          brillo: 255,
          patron: 3,
          offsetMs: offset,
        );
        onCommand(cmd);
        _nextBeatIdx++;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _syntheticTimer?.cancel();
    _nextBeatIdx = 0;
  }

  void dispose() {
    _timer?.cancel();
    _syntheticTimer?.cancel();
  }
}
