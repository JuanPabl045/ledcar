import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/ble_manager.dart';
import '../services/audio_capture_service.dart';

class LedCommand {
  final int tipo, r, g, b, brillo, patron, offsetMs;
  const LedCommand({
    required this.tipo,
    required this.r,
    required this.g,
    required this.b,
    required this.brillo,
    required this.patron,
    this.offsetMs = 0,
  });
  List<int> toBytes() => [
    tipo & 0xFF,
    r.clamp(0, 255),
    g.clamp(0, 255),
    b.clamp(0, 255),
    brillo.clamp(0, 255),
    patron.clamp(0, 255),
    (offsetMs >> 8) & 0xFF,
    offsetMs & 0xFF,
  ];
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // BLE
  final BleManager _ble = BleManager();
  bool _bleConnected = false;
  bool _bleScanning = false;
  int _iaRxCount = 0;
  int _lastIaLogMs = 0;
  int _lastBleRetryMs = 0;

  // Manual
  bool _modoManual = false;
  Color _colorManual = const Color(0xFF222244);
  bool _isSilence = false;

  // IA
  AudioCaptureService? _audioCapture;
  bool _iaActive = false;
  String _detectedClass = '';
  String _detectedSection = '';
  String _lastInstrument = 'mixed';
  bool _isEnergetic = false;
  List<int>? _lastSentBytes;
  int _beatBpm = 0;
  double _beatConf = 0.0;
  double _beatIntervalMs = 0.0;
  double _onsetStrength = 0.0;
  int _lastOnsetMs = 0;
  String _emotionLabel = '';
  double _emotionConf = 0.0;
  int _emotionR = 0;
  int _emotionG = 0;
  int _emotionB = 0;

  // Color lerp
  double _curR = 255, _curG = 40, _curB = 40;
  double _targetR = 255, _targetG = 40, _targetB = 40;

  static const int _fallbackR = 255;
  static const int _fallbackG = 40;
  static const int _fallbackB = 40;
  int _cachedPatron = 0;

  // EMA / dynamics
  double _smoothE = 0, _smoothBass = 0;
  double _dynMin = 1.0, _dynMax = 0.0;
  double _brilloEnv = 0.0;

  // Settings
  double _intensidadGlobal = 1.2;
  double _lerpSpeed = 0.18; // transiciones más visibles
  double _emaAlpha = 0.0; // DESACTIVAR EMA en Dart — Kotlin ya lo hace
  double _brAttack = 0.85; // subida casi instantánea
  double _brRelease = 0.35; // bajada más rápida para contraste
  double _maxBri = 240.0;
  double _gamma = 1.8; // Filosofía Log-Mel: Gama > 1.0 hace que los bajos sean oscuros y los picos explosivos
  double _silenceThreshold = 0.015; // Umbral más permisivo para no cortar notas sostenidas suaves
  bool _settingsExpanded = false;

  static const double _defIntensidadGlobal = 1.2;
  static const double _defLerpSpeed = 0.18;
  static const double _defEmaAlpha = 0.0;
  static const double _defBrAttack = 0.85;
  static const double _defBrRelease = 0.35;
  static const double _defMaxBri = 240.0;
  static const double _defGamma = 1.8;
  static const double _defSilenceThreshold = 0.015;

  bool _shouldSendBytes(List<int> next) {
    if (_lastSentBytes == null) return true;
    final prev = _lastSentBytes!;
    if (prev.length != next.length) return true;
    for (var i = 0; i < next.length; i++) {
      if ((next[i] - prev[i]).abs() >= 2) return true;
    }
    return false;
  }

  void _sendLedCommand(LedCommand command) {
    final bytes = command.toBytes();
    if (!_shouldSendBytes(bytes)) return;
    _lastSentBytes = List<int>.from(bytes);
    _ble.sendCommand(bytes);
  }

  void _restoreDefaults() => setState(() {
    _lerpSpeed = _defLerpSpeed;
    _emaAlpha = _defEmaAlpha;
    _brAttack = _defBrAttack;
    _brRelease = _defBrRelease;
    _maxBri = _defMaxBri;
    _gamma = _defGamma;
    _silenceThreshold = _defSilenceThreshold;
    _intensidadGlobal = _defIntensidadGlobal;
  });

  double _normalizeDynamic(double raw) {
    final x = raw.clamp(0.0, 1.0);
    
    // Floor: sigue rápido hacia abajo, instantáneo en silencios
    if (x < _dynMin) {
      _dynMin = x * 0.3 + _dynMin * 0.7;  // cae rápido
      if (x < 0.03) _dynMin = x; // Drop total al abismo en silencios
    } else {
      _dynMin = _dynMin + 0.005 * (x - _dynMin);  // sube muy lento
    }
    
    // Ceiling: MACRO DINÁMICA. Sube rápido, pero baja EXTREMADAMENTE lento.
    // Esto preserva el volumen general de la canción.
    if (x > _dynMax) {
      _dynMax = x * 0.6 + _dynMax * 0.4;  // sube rapidísimo en picos
    } else {
      _dynMax = _dynMax + 0.002 * (x - _dynMax);  // baja súper lento (10x más lento)
    }
    
    // EL TRUCO PARA EL INTRO: El techo dinámico NUNCA baja de 0.40.
    // Si la canción está en intro (x = 0.15), el techo será 0.40.
    // Por tanto, el valor normalizado será 0.15/0.40 = 0.375 (LEDs bajos y coherentes)
    _dynMax = math.max(0.40, _dynMax);
    
    // Rango mínimo elevado para evitar que el ruido se amplifique al 100%
    final range = math.max(0.25, _dynMax - _dynMin);
    return ((x - _dynMin) / range).clamp(0.0, 1.0);
  }

  double _musicPulse(int nowMs) {
    if (_beatBpm <= 0 || _beatIntervalMs < 180 || _beatConf < 0.15) {
      return 1.0;
    }

    final cycle = (nowMs % _beatIntervalMs) / _beatIntervalMs;
    final beatWave = math.sin(cycle * math.pi * 2).abs();
    final pulse = math.pow(beatWave, 0.7).toDouble();
    return 0.74 + (0.52 * pulse);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ble.connectionStream.listen((c) {
      if (!c) _lastSentBytes = null;
      setState(() => _bleConnected = c);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _iaActive &&
        _audioCapture != null) {
      debugPrint('App resumed: reconectando listener IA');
      _audioCapture!.reconnectListener();
    }
  }

  Future<void> _startAudioCapture() async {
    if (_modoManual) return;
    if (_iaActive) {
      _audioCapture?.stop();
      setState(() {
        _iaActive = false;
        _detectedClass = '';
        _detectedSection = '';
      });
      return;
    }

    _audioCapture = AudioCaptureService(
      onResult: (result) {
        _iaRxCount++;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if ((nowMs - _lastIaLogMs) > 1500) {
          _lastIaLogMs = nowMs;
          debugPrint(
            'IA: rx=$_iaRxCount fast=${result.isFastUpdate} e=${result.energy.toStringAsFixed(3)} ble=$_bleConnected',
          );
        }
        if (result.beatBpm > 0) {
          _beatBpm = result.beatBpm;
          _beatConf = result.beatConfidence;
          _beatIntervalMs = result.beatIntervalMs;
        }
        _onsetStrength = result.onsetStrength;
        if (result.isOnset) _lastOnsetMs = nowMs;
        if (result.emotionLabel.isNotEmpty) {
          _emotionLabel = result.emotionLabel;
          _emotionConf = result.emotionConfidence;
          _emotionR = result.emotionR;
          _emotionG = result.emotionG;
          _emotionB = result.emotionB;
        }

        if (!_bleConnected) {
          if ((nowMs - _lastBleRetryMs) > 5000 && !_bleScanning) {
            _lastBleRetryMs = nowMs;
            _connectBle();
          }
          return;
        }

        if (result.energy < _silenceThreshold) {
          if (!_isSilence) {
            _isSilence = true;
            _dynMin = 1.0;
            _dynMax = 0.0;
            _brilloEnv = 0.0;
            _sendLedCommand(
              const LedCommand(
                tipo: 0x01,
                r: 0,
                g: 0,
                b: 0,
                brillo: 0,
                patron: 0,
              ),
            );
            setState(() {
              _detectedClass = 'Silencio';
              _detectedSection = '';
            });
          }
          return;
        }

        if (_isSilence) _isSilence = false;

        final e = result.energy.clamp(0.0, 1.0);
        final bass = result.bassEnergy.clamp(0.0, 1.0);
        _smoothE = _smoothE + _emaAlpha * (e - _smoothE);
        _smoothBass = _smoothBass + _emaAlpha * (bass - _smoothBass);

        if (_modoManual) return;

        if (result.isFastUpdate) {
          // Filosofía Log-Mel: Percepción exponencial y separación de ruido
          final e    = result.energy.clamp(0.0, 1.0);
          final bass = result.bassEnergy.clamp(0.0, 1.0);
          final inst = _lastInstrument;
          
          // --- DINÁMICA DE COLOR EN TIEMPO REAL (LOW POWER MODE) ---
          // Para proteger tu fuente actual, usamos colores que solo encienden
          // 1 o 2 canales a la vez (Rojo y un poco de Azul/Verde), evitando el Blanco.
          double tR = 255.0, tG = 0.0, tB = 0.0;
          
          if (inst == 'bass') {
            // Bajos: Rojo violáceo (Canal R fuerte, Canal B medio)
            tR = 220.0;
            tG = 0.0;
            tB = (40 + 120 * bass).clamp(0, 255).toDouble();
          } else if (inst == 'drums') {
            // Batería: Naranja oscuro (Canal R fuerte, Canal G bajo)
            tR = 255.0;
            tG = (20 + 80 * e).clamp(0, 255).toDouble();
            tB = 0.0;
          } else if (inst == 'vocals') {
            // Voces: Rojo puro pulsante
            tR = (180 + 75 * e).clamp(0, 255).toDouble();
            tG = 0.0;
            tB = 0.0;
          } else {
            // Default: Rojo base con destellos cálidos
            tR = 255.0;
            tG = (10 + 40 * e).clamp(0, 255).toDouble();
            tB = 10.0;
          }

          // Aceleramos la transición de color (0.35)
          _curR += (tR - _curR) * 0.35;
          _curG += (tG - _curG) * 0.35;
          _curB += (tB - _curB) * 0.35;

          final r = _curR.round().clamp(0, 255);
          final g = _curG.round().clamp(0, 255);
          final b = _curB.round().clamp(0, 255);

          double wE, wB, atk, rel;
          switch (inst) {
            case 'drums': wE=0.50; wB=0.50; atk=1.0; rel=0.15; break;
            case 'bass':  wE=0.30; wB=0.70; atk=0.8; rel=0.30; break;
            case 'vocals':wE=0.80; wB=0.10; atk=0.6; rel=0.50; break;
            default:      wE=0.55; wB=0.45; atk=0.8; rel=0.25; break;
          }

          final raw = (e * wE + bass * wB).clamp(0.0, 1.0);
          final dyn = _normalizeDynamic(raw);
          
          // Expansión cuadrática para hundir el piso (Log-Mel perceptual)
          final expandedDyn = math.pow(dyn, 2.0).toDouble();
          
          // Gate estricto basado en silencio real
          final gate = e < _silenceThreshold 
              ? 0.0 
              : ((e - _silenceThreshold) / 0.15).clamp(0.0, 1.0);
              
          // Diferencia DRAMÁTICA entre Coro y Verso
          // Si estamos en el coro (_isEnergetic), la intensidad pasa al 100%. 
          // Si estamos en un verso, reducimos la agresividad de la señal a un 75%.
          final double sectionMultiplier = _isEnergetic ? 1.0 : 0.75;
          
          // El dyn expandido lleva la mayoría del peso para hacer explosivos los picos
          final intensity = ((raw * 0.15 + expandedDyn * 0.85) * gate * sectionMultiplier).clamp(0.0, 1.0);

          // Aquí está el truco visual: El PWM máximo en los versos se capa a la mitad.
          // Así, cuando entra el coro y salta de 50% a 100%, el salto es masivo.
          final maxBri = _isEnergetic ? _maxBri.round() : (_maxBri * 0.50).round();
          
          // Forzar que el gamma no aplane (Gamma < 1 empantana todo en luz media)
          final gam = _gamma < 1.0 ? 1.8 : _gamma;

          int brillo = (maxBri * math.pow(intensity, gam)).round();
          brillo = (brillo * _intensidadGlobal).clamp(0, 255).round();

          // Bypass absoluto para golpes percusivos
          final bool hit = result.kickHit || result.snareHit;
          if (result.kickHit) {
            brillo = math.max(brillo, maxBri);
          } else if (result.snareHit) {
            brillo = math.max(brillo, (maxBri * 0.85).round());
          }

          if (hit) {
            _brilloEnv = brillo.toDouble();
          } else {
            final brRate = brillo > _brilloEnv ? _brAttack * atk : _brRelease * rel;
            _brilloEnv += (brillo - _brilloEnv) * brRate;
          }
          
          // Drop al vacío en silencios, pero un poco más suave para no cortarlo bruscamente
          if (gate == 0.0) _brilloEnv *= 0.75;
          
          brillo = _brilloEnv.round().clamp(0, 255);

          // Eliminados los fogonazos blancos para proteger la fuente.
          int oR = r, oG = g, oB = b;

          _ble.sendCommand(LedCommand(
            tipo:0x01, r:oR, g:oG, b:oB,
            brillo:brillo, patron:_cachedPatron,
          ).toBytes());
          return;
        }

        // SLOW PATH
        final section = result.section;
        final sConf = result.sectionConfidence;
        final inst = result.instrument.isNotEmpty
            ? result.instrument
            : _lastInstrument;
        if (result.instrument.isNotEmpty) _lastInstrument = result.instrument;

        _isEnergetic = section == 'chorus';
        final emotionBlend = (_emotionLabel.isNotEmpty && _emotionConf > 0.55)
            ? (0.25 + 0.35 * ((_emotionConf - 0.55) / 0.45).clamp(0.0, 1.0))
            : 0.0;
        if (inst == 'bass') {
          _targetR = (30 + 70 * (1 - _smoothBass)).clamp(0, 255).toDouble();
          _targetG = (70 + 55 * _smoothBass).clamp(0, 255).toDouble();
          _targetB = (170 + 70 * _smoothBass).clamp(0, 255).toDouble();
        } else if (inst == 'drums') {
          _targetR = (170 + 65 * _smoothBass).clamp(0, 255).toDouble();
          _targetG = (55 + 35 * _smoothE).clamp(0, 255).toDouble();
          _targetB = (35 + 20 * _smoothE).clamp(0, 255).toDouble();
        } else if (inst == 'vocals' && _isEnergetic) {
          final vocalLift = (_emotionConf > 0.0 ? _emotionConf : 0.0).clamp(
            0.0,
            1.0,
          );
          _targetR = (220 + 25 * vocalLift).clamp(0, 255).toDouble();
          _targetG = (120 + 80 * vocalLift).clamp(0, 255).toDouble();
          _targetB = (140 + 55 * (1 - vocalLift)).clamp(0, 255).toDouble();
        } else {
          _targetR =
              (_fallbackR * (1 - emotionBlend) + _emotionR * emotionBlend)
                  .clamp(0, 255)
                  .toDouble();
          _targetG =
              (_fallbackG * (1 - emotionBlend) + _emotionG * emotionBlend)
                  .clamp(0, 255)
                  .toDouble();
          _targetB =
              (_fallbackB * (1 - emotionBlend) + _emotionB * emotionBlend)
                  .clamp(0, 255)
                  .toDouble();
        }
        _cachedPatron = (_isEnergetic && sConf > 0.6) ? 1 : 0;

        final cR = _curR.round().clamp(0, 255);
        final cG = _curG.round().clamp(0, 255);
        final cB = _curB.round().clamp(0, 255);
        final si = _smoothE.clamp(0.0, 1.0);
        final sb = _smoothBass.clamp(0.0, 1.0);
        final gateSlow = ((_smoothE - 0.03) / 0.16).clamp(0.0, 1.0);
        final pulse = _musicPulse(nowMs);
        final kickPulse = (result.kickHit || result.snareHit) ? 1.0 : 0.0;
        double drive;
        double curvePow;
        double sectionBoost;
        if (inst == 'bass') {
          drive = (sb * 0.88 + si * 0.12 + gateSlow * 0.18).clamp(0.0, 1.0);
          curvePow = 0.56;
          sectionBoost = 1.18;
        } else if (inst == 'vocals' && _isEnergetic) {
          drive = (si * 0.70 + gateSlow * 0.16 + _emotionConf * 0.14).clamp(
            0.0,
            1.0,
          );
          curvePow = 0.60;
          sectionBoost = 1.32;
        } else if (inst == 'drums') {
          drive = (si * 0.36 + gateSlow * 0.22 + kickPulse * 0.42).clamp(
            0.0,
            1.0,
          );
          curvePow = 0.58;
          sectionBoost = 1.15;
        } else {
          drive = (si * 0.54 + sb * 0.24 + gateSlow * 0.22).clamp(0.0, 1.0);
          curvePow = _isEnergetic ? 0.64 : 0.78;
          sectionBoost = _isEnergetic ? 1.16 : 0.96;
        }
        final motion = (drive * pulse).clamp(0.0, 1.0);
        final curve = math.pow(motion, curvePow).toDouble();
        final stb = (255.0 * curve * sectionBoost).round().clamp(0, 255);
        final brs = stb >= _brilloEnv
            ? (_brAttack * 1.12)
            : (_brRelease * 0.92);
        _brilloEnv = _brilloEnv + (stb - _brilloEnv) * brs;
        var br = _brilloEnv.round().clamp(0, 255);
        br = (br * _intensidadGlobal).clamp(0, 255).round();
        // Evitar pequeños valores residuales que mantienen el led encendido
        if (br < 8) br = 0;

        int oR = cR, oG = cG, oB = cB;
        if (cR >= 250 && cG >= 250 && cB >= 250) {
          oR = 255;
          oG = 190;
          oB = 120;
        }
        _sendLedCommand(
          LedCommand(
            tipo: 0x01,
            r: oR,
            g: oG,
            b: oB,
            brillo: br,
            patron: _cachedPatron,
          ),
        );

        setState(() {
          if (_emotionLabel.isNotEmpty) _detectedClass = _emotionLabel;
          _detectedSection = _isEnergetic
              ? 'CHORUS ${(sConf * 100).toInt()}%'
              : 'verse';
        });
      },
    );

    final ok = await _audioCapture!.requestPermissionAndStart();
    if (ok) setState(() => _iaActive = true);
    debugPrint('AudioCapture iniciado: $ok');
  }

  Future<void> _connectBle() async {
    setState(() => _bleScanning = true);
    try {
      await _ble.connect();
    } catch (e) {
      debugPrint('BLE error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('BLE: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _bleScanning = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ble.dispose();
    _audioCapture?.dispose();
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(child: _buildMain()),
    );
  }

  Widget _buildMain() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          _buildIaCard(),
          const SizedBox(height: 16),
          _buildBleCard(),
          const SizedBox(height: 16),
          _buildSettingsCard(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return const Text(
      'LedCar',
      style: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildIaCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _iaActive ? const Color(0xFF7F77DD) : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'IA Musical',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _iaActive
                        ? (_detectedClass.isNotEmpty
                              ? _detectedClass
                              : 'Escuchando...')
                        : 'Toca Iniciar IA',
                    style: TextStyle(
                      color: _iaActive
                          ? const Color(0xFF7F77DD)
                          : Colors.white38,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: _startAudioCapture,
                icon: Icon(_iaActive ? Icons.stop : Icons.mic),
                label: Text(_iaActive ? 'Detener' : 'Iniciar IA'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _iaActive
                      ? Colors.red.shade900
                      : const Color(0xFF7F77DD),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          if (_iaActive) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (_lastInstrument != 'mixed')
                  _chip('Inst: $_lastInstrument', Colors.teal),
                if (_beatBpm > 0) _chip('BPM: $_beatBpm', Colors.green),
                if (_emotionLabel.isNotEmpty)
                  _chip('Emo: $_emotionLabel', Colors.amber),
                if (_detectedSection.isNotEmpty)
                  _chip(
                    _detectedSection,
                    _isEnergetic ? Colors.orange : Colors.blueGrey,
                  ),
              ],
            ),
            if (_detectedClass.isNotEmpty) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: null,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation(Color(0xFF7F77DD)),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildBleCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ESP32 LedCar',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                _bleConnected
                    ? 'Conectado — ${_ble.measuredLatencyMs}ms'
                    : _bleScanning
                    ? 'Buscando...'
                    : 'Desconectado',
                style: TextStyle(
                  color: _bleConnected ? Colors.green : Colors.white38,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          ElevatedButton(
            onPressed: _bleScanning
                ? null
                : _bleConnected
                ? () async {
                    await _ble.disconnect();
                  }
                : _connectBle,
            style: ElevatedButton.styleFrom(
              backgroundColor: _bleConnected
                  ? Colors.red.shade900
                  : const Color(0xFF1A56DB),
              foregroundColor: Colors.white,
            ),
            child: Text(
              _bleConnected
                  ? 'Desconectar'
                  : _bleScanning
                  ? 'Buscando...'
                  : 'Conectar',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _settingsExpanded = !_settingsExpanded),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.tune, color: Colors.white70, size: 20),
                      SizedBox(width: 10),
                      Text(
                        'Ajustes',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Icon(
                    _settingsExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
          if (_settingsExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                children: [
                  _buildManualColorRow(),
                  const SizedBox(height: 10),
                  _slider(
                    'Sensibilidad',
                    _emaAlpha,
                    0.1,
                    1.0,
                    (v) => _emaAlpha = v,
                    desc: 'Reactividad al audio',
                  ),
                  _slider(
                    'Vel. subida',
                    _brAttack,
                    0.05,
                    1.0,
                    (v) => _brAttack = v,
                    desc: 'Rapidez con que sube el brillo',
                  ),
                  _slider(
                    'Vel. bajada',
                    _brRelease,
                    0.02,
                    0.5,
                    (v) => _brRelease = v,
                    desc: 'Cuanto tarda en apagarse',
                  ),
                  _slider(
                    'Trans. color',
                    _lerpSpeed,
                    0.01,
                    0.5,
                    (v) => _lerpSpeed = v,
                    desc: 'Velocidad cambio de color',
                  ),
                  _slider(
                    'Brillo max',
                    _maxBri,
                    50,
                    255,
                    (v) => _maxBri = v,
                    desc: 'Limite de brillo',
                  ),
                  _slider(
                    'Intensidad',
                    _intensidadGlobal,
                    0.2,
                    2.0,
                    (v) => _intensidadGlobal = v,
                    desc: 'Multiplica el brillo IA',
                  ),
                  _slider(
                    'Contraste',
                    _gamma,
                    0.4,
                    2.0,
                    (v) => _gamma = v,
                    desc: 'Bajo=luz suave, Alto=solo picos',
                  ),
                  _slider(
                    'Umbral silencio',
                    _silenceThreshold,
                    0.01,
                    0.10,
                    (v) => _silenceThreshold = v,
                    desc: 'Energia minima para encender',
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _restoreDefaults,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('Restaurar valores'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white54,
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildManualColorRow() {
    final presets = [
      [const Color(0xFFFFBE78), 'Ámbar'],
      [const Color(0xFF1A237E), 'Azul'],
      [const Color(0xFF145A32), 'Verde'],
      [const Color(0xFF8B0000), 'Rojo'],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                icon: Icon(
                  _modoManual ? Icons.lightbulb : Icons.lightbulb_outline,
                ),
                label: Text(_modoManual ? 'Modo IA' : 'Color manual'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _modoManual
                      ? Colors.orange
                      : Colors.blueGrey,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  if (_modoManual) {
                    setState(() => _modoManual = false);
                  } else {
                    _audioCapture?.stop();
                    setState(() {
                      _modoManual = true;
                      _iaActive = false;
                    });
                  }
                },
              ),
            ),
            if (_modoManual)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _colorManual,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ],
        ),
        if (_modoManual) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            children: presets.map((p) {
              final c = p[0] as Color;
              final n = p[1] as String;
              return ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: c,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: () {
                  setState(() => _colorManual = c);
                  _sendLedCommand(
                    LedCommand(
                      tipo: 0x01,
                      r: c.red,
                      g: c.green,
                      b: c.blue,
                      brillo: 255,
                      patron: 0,
                    ),
                  );
                },
                child: Text(n),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) onChanged, {
    String desc = '',
  }) {
    final isInt = max > 100;
    final display = isInt ? value.round().toString() : value.toStringAsFixed(2);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Text(
                display,
                style: const TextStyle(
                  color: Color(0xFF7F77DD),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: const Color(0xFF7F77DD),
              inactiveTrackColor: Colors.white12,
              thumbColor: const Color(0xFF7F77DD),
              overlayColor: const Color(0xFF7F77DD).withValues(alpha: 0.15),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: (v) => setState(() => onChanged(v)),
            ),
          ),
          if (desc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                desc,
                style: const TextStyle(color: Colors.white24, fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }
}
