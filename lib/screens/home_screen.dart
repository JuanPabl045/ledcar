import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/ble_manager.dart';
import '../services/audio_capture_service.dart';
import '../widgets/debug_visualizer.dart';

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
  int _lastFrameMs = 0;

  final ValueNotifier<DebugData> _debugNotifier = ValueNotifier(
    DebugData(si: 0, tension: 0, drumEnv: 0, drive: 0),
  );

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
  double _lastCentroid = 0.0;
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
  int _overrideToHighEnergyUntilMs = 0;

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
  double _driveEma = 0.0; // Moving average de la línea roja (Luz)

  // Inercia Visual (Director de Orquesta)
  double _wBassEma = 0.5;
  double _wVocalsEma = 0.5;
  double _wDrumsEma = 0.5;
  double _wEnergyEma = 0.5;
  double _sectionBoostEma = 1.0;
  double _drumEnvelope = 0.0;

  // Settings
  double _intensidadGlobal = 1.2;
  double _lerpSpeed = 0.18; // transiciones más visibles
  double _emaAlpha = 0.0; // DESACTIVAR EMA en Dart — Kotlin ya lo hace
  double _brAttack = 0.85; // subida casi instantánea
  double _brRelease = 0.18; // bajada más suave para dejar un rastro (afterglow)
  double _maxBri = 240.0;
  double _gamma = 2.4; // Filosofía Log-Mel: Gama > 1.0 hace que los bajos sean oscuros y los picos explosivos
  double _silenceThreshold = 0.015; // Umbral más permisivo para no cortar notas sostenidas suaves
  bool _settingsExpanded = false;

  static const double _defIntensidadGlobal = 1.2;
  static const double _defLerpSpeed = 0.18;
  static const double _defEmaAlpha = 0.0;
  static const double _defBrAttack = 0.85;
  static const double _defBrRelease = 0.18;
  static const double _defMaxBri = 240.0;
  static const double _defGamma = 2.4;
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

        // Eliminamos el early-return de silencio. 
        // Queremos que el DSP siga trabajando incluso si hay puro silencio (puros ceros),
        // para que las variables decaigan suavemente a cero y no se quede pegado ningún LED.

        final e = result.energy.clamp(0.0, 1.0);
        final bass = result.bassEnergy.clamp(0.0, 1.0);
        _smoothE = _smoothE + _emaAlpha * (e - _smoothE);
        _smoothBass = _smoothBass + _emaAlpha * (bass - _smoothBass);

        if (_modoManual) return;

        if (result.isFastUpdate) {
          final e = result.energy.clamp(0.0, 1.0);
          final bass = result.bassEnergy.clamp(0.0, 1.0);
          final vocal = result.vocalEnergy.clamp(0.0, 1.0);
          double tension = result.tension.clamp(0.0, 1.0);
          
          // INYECCIÓN VOCAL: FFT pura sin IA.
          // Reducimos el impacto de la voz al mínimo (0.05) por precaución de voltaje.
          tension = (tension + (vocal * 0.05)).clamp(0.0, 1.0);
          
          // HIBRIDACIÓN DE TENSIÓN: 
          // Si el modelo dice que es el coro, mezclamos (50/50) la Tensión (Sorpresa) con el Promedio Rápido (Suma de Pesos).
          // Esto soluciona la gráfica plana: ahora el Azul bailará agresivamente y rara vez se quedará pegado al 1.0, 
          // protegiendo tu fuente de caídas de voltaje por culpa del Amarillo.
          if (_isEnergetic) {
            tension = ((tension + _driveEma) / 2.0).clamp(0.0, 1.0);
          }
          
          final si = _smoothE.clamp(0.0, 1.0);
          final sb = _smoothBass.clamp(0.0, 1.0);
          final pulse = _musicPulse(nowMs);
          final kickPulse = (result.kickHit || result.snareHit) ? 1.0 : 0.0;
          
          int dt = 0;
          if (_lastFrameMs > 0) dt = nowMs - _lastFrameMs;
          _lastFrameMs = nowMs;

          // Anulación Híbrida (DSP + IA)
          String activeLabel = _emotionLabel;
          
          if (tension > 0.60) {
            _overrideToHighEnergyUntilMs = nowMs + 3000;
          }
          if (e > 0.42 && (result.kickHit || result.snareHit)) {
            _overrideToHighEnergyUntilMs = nowMs + 2500;
          }
          if (nowMs < _overrideToHighEnergyUntilMs && activeLabel == 'acustico') {
            activeLabel = 'energetico';
          }

          // --- 1. ROL DEL MODELO (El Director) ---
          double tWBass = 0.0;
          double tWVocals = 0.0;
          double tWDrums = 0.0;
          double tWEnergy = 0.0;
          double tBoost = 1.0;
          
          if (_lastInstrument == 'bass') {
            tWBass = 1.0; 
            tWDrums = 0.30;
            tWVocals = 0.10;
            tWEnergy = 0.20;
            tBoost = 1.15;
          } else if (_lastInstrument == 'vocals') {
            tWVocals = 1.0;
            tWDrums = 0.30;  
            tWBass = 0.20;
            tWEnergy = 0.30;
            tBoost = 1.25;
          } else if (_lastInstrument == 'drums') {
            tWDrums = 1.20; 
            tWBass = 0.30;
            tWVocals = 0.10;
            tWEnergy = 0.20;
            tBoost = 1.35;
          } else {
            tWBass = 0.50;
            tWVocals = 0.50;
            tWDrums = 0.60;
            tWEnergy = 0.40;
            tBoost = 1.0;
          }
          
          if (_isEnergetic) {
            tBoost *= 1.25; // Más brillo en el coro
          }

          // --- 4. COLOR DINÁMICO POR CENTROIDE ESPECTRAL (PALETA FUEGO) ---
          
          double rawActivator = tension.clamp(0.0, 1.0);
          double glow = math.pow(rawActivator, 2.0).toDouble();
          
          // Mapeamos el centroide de 0Hz a 4000Hz a una escala de 0.0 a 1.0
          double normCentroid = (result.spectralCentroid / 4000.0).clamp(0.0, 1.0);
          
          // Interpolación suave del Centroide
          _lastCentroid = (_lastCentroid * 0.85) + (normCentroid * 0.15);
          
          // El Rojo siempre es la base inamovible
          _targetR = 255.0;
          
          // Mientras más alto el centroide (agudos), más verde inyectamos para calentar a Amarillo/Ámbar
          _targetG = _lastCentroid * 200.0; 
          _targetB = 0.0;
          
          // Destello de Clímax (Blanco)
          if (glow > 0.5) {
             double extra = (glow - 0.5) * 2.0; 
             _targetG += (extra * 55.0);  
             _targetB += (extra * 255.0); 
          }
          
          _targetR = _targetR.clamp(0.0, 255.0);
          _targetG = _targetG.clamp(0.0, 255.0);
          _targetB = _targetB.clamp(0.0, 255.0);

          // Transición de color EXTREMADAMENTE suave (amigable)
          const double slowColorLerp = 0.015; // ~1.5 segundos para cambiar de color
          _curR += (_targetR - _curR) * slowColorLerp;
          _curG += (_targetG - _curG) * slowColorLerp;
          _curB += (_targetB - _curB) * slowColorLerp;
          final r = _curR.round().clamp(0, 255);
          final g = _curG.round().clamp(0, 255);
          final b = _curB.round().clamp(0, 255);

          // --- 3. FILTRO DE INERCIA VISUAL (Slew Rate Limiter / EMA) ---
          const double emaSlew = 0.08; 
          _wBassEma = (tWBass * emaSlew) + (_wBassEma * (1.0 - emaSlew));
          _wVocalsEma = (tWVocals * emaSlew) + (_wVocalsEma * (1.0 - emaSlew));
          _wDrumsEma = (tWDrums * emaSlew) + (_wDrumsEma * (1.0 - emaSlew));
          _wEnergyEma = (tWEnergy * emaSlew) + (_wEnergyEma * (1.0 - emaSlew));
          _sectionBoostEma = (tBoost * emaSlew) + (_sectionBoostEma * (1.0 - emaSlew));

          // --- 2. GENERACIÓN DE PESOS DINÁMICOS ---
          double dynBass = math.max(0.0, sb - 0.15);
          double dynVocal = math.max(0.0, vocal - 0.15);
          double dynEnergy = math.max(0.0, si - 0.20);
          
          // Interpolación Percusiva (Envolvente suave en lugar de parpadeo binario)
          if (result.kickHit || result.snareHit) {
            _drumEnvelope = 1.0;
          } else {
            _drumEnvelope *= 0.82; // Caída exponencial muy musical (~100ms)
          }
          
          double rawDrive = 
              (dynBass * _wBassEma) + 
              (dynVocal * _wVocalsEma) + 
              (_drumEnvelope * _wDrumsEma) + 
              (dynEnergy * _wEnergyEma);

          // Quitamos la supresión (divisor) para que recupere toda su fuerza
          double drive = rawDrive.clamp(0.0, 1.0);
          final motion = (drive * pulse).clamp(0.0, 1.0);
          
          // Actualizamos la Memoria de Luz (Línea Roja) para el siguiente frame.
          // Usamos un factor de 0.35 para que reaccione rapidísimo y varíe mucho, evitando que sea una línea plana.
          _driveEma = _driveEma + 0.35 * (drive - _driveEma);
          
          _debugNotifier.value = DebugData(
            si: si, 
            tension: tension, 
            drumEnv: _drumEnvelope, 
            drive: rawDrive, // Enviamos el valor crudo para ver si satura (clipping)
            dt: dt,
          );
          
          final curve = math.pow(motion, _gamma).toDouble();
          
          // WS2815 12V UNLEASHED: Ya no limitamos la energía al 25% para evitar caídas de voltaje.
          // Le damos el 100% de fuerza bruta.
          final maxBriFactor = 1.0; 
          final maxBri = (_maxBri * maxBriFactor).round();

          int brillo = (maxBri * curve * _sectionBoostEma).round();

          // Capa 3: Ya no inyectamos base plana, dejamos que la gráfica baje a 0 para más dinámica
          brillo = (brillo * _intensidadGlobal).clamp(0, 255).round();

          // Gate Anti-Ruido: Si hay pausa, pero hay ruido ambiental (motor), forzamos a apagar
          final gate = e < 0.02 ? 0.0 : ((e - 0.02) / 0.1).clamp(0.0, 1.0);
          brillo = (brillo * gate).round(); 

          // Envelope DINÁMICO (Se adapta a la canción!)
          double attack = 0.65;
          double release = 0.15;
          
          if (_isEnergetic) {
             // ROCK/EDM: Súper agresivo, cero lag, casi estroboscópico
             attack = 0.85;
             release = 0.40;
          } else if (_detectedClass == 'groove') {
             // TRAP/REGGAE/POP: Intermedio, buen rebote
             attack = 0.70;
             release = 0.18;
          } else {
             // ACÚSTICO/CHILL: Suave, cinemático, cambios lentos y respirables
             attack = 0.45;
             release = 0.08;
          }

          final brs = brillo >= _brilloEnv ? attack : release;
          _brilloEnv = _brilloEnv + (brillo - _brilloEnv) * brs;
          
          if (gate == 0.0) _brilloEnv *= 0.60; // Si es puro silencio, mátalo rápido

          var br = _brilloEnv.round().clamp(0, 255);
          if (br < 5) br = 0;

          // Forzar blanco cálido si todo satura
          int oR = r, oG = g, oB = b;
          if (r >= 250 && g >= 250 && b >= 250) {
            oR = 255; oG = 190; oB = 120;
          }

          _ble.sendCommand(LedCommand(
            tipo: 0x01, 
            r: oR, 
            g: oG, 
            b: oB,
            brillo: br, 
            patron: _cachedPatron,
          ).toBytes());
          return;
        }

        // SLOW PATH (Ejecución ML 1Hz)
        if (result.instrument.isNotEmpty) _lastInstrument = result.instrument;
        
        // Mapeamos las salidas reales del modelo ('energetico', 'groove', 'acustico')
        if (result.emotionLabel.isNotEmpty) {
          _isEnergetic = result.emotionLabel == 'energetico';
        }

        _cachedPatron = (_isEnergetic && result.emotionConfidence > 0.6) ? 1 : 0;
        
        setState(() {
          if (result.emotionLabel.isNotEmpty) _detectedClass = result.emotionLabel;
          _detectedSection = _isEnergetic ? 'CORO/ENERGÉTICO' : 'VERSO/TRANQUILO';
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
            DebugVisualizer(notifier: _debugNotifier),
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
