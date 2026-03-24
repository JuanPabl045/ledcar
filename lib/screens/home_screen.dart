import 'dart:async';
import 'package:flutter/material.dart';
import '../services/spotify_auth.dart';
import '../services/spotify_api.dart';
import '../services/ble_manager.dart';
import '../engine/reaction_engine.dart';
import '../engine/beat_scheduler.dart';
import 'package:ledcar/services/lastfm_api.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _currentGenre = 'default';
  int _currentBpm = 110;
  // Spotify
  String? _token;
  bool _loading = false;
  SpotifyApiService? _api;
  CurrentTrack? _currentTrack;
  TrackAnalysis? _analysis;

  // BLE
  final BleManager _ble = BleManager();
  bool _bleConnected = false;
  bool _bleScanning = false;

  // Engine
  late BeatScheduler _scheduler;
  Timer? _trackPoller;
  int _playheadMs = 0;
  String _reactionMode = 'energy'; // energy | valence | genre

  @override
  void initState() {
    super.initState();
    _scheduler = BeatScheduler(
      onCommand: (cmd) => _ble.sendCommand(cmd.toBytes()),
    );
    _ble.connectionStream.listen((connected) {
      setState(() => _bleConnected = connected);
      if (connected) {
        _scheduler.setLatency(_ble.measuredLatencyMs);
      }
    });
    _checkExistingToken();
  }

  Future<void> _checkExistingToken() async {
    final token = await SpotifyAuth.getToken();
    if (token != null) {
      setState(() {
        _token = token;
        _api = SpotifyApiService(token);
      });
      _startTrackPoller();
    }
  }

  Future<void> _login() async {
    setState(() => _loading = true);
    try {
      final token = await SpotifyAuth.login();
      if (token != null) {
        setState(() {
          _token = token;
          _api = SpotifyApiService(token);
        });
        _startTrackPoller();
      }
    } catch (e) {
      debugPrint('Login error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _loading = false);
    }
  }

  // Consulta cada 1 segundo que cancion esta sonando
  void _startTrackPoller() {
    _trackPoller?.cancel();
    _trackPoller = Timer.periodic(const Duration(seconds: 1), (_) async {
      await _pollCurrentTrack();
    });
    _pollCurrentTrack();
  }

  String? _lastTrackId;

  Future<void> _pollCurrentTrack() async {
    if (_api == null) return;
    final track = await _api!.getCurrentTrack();

    // Si no hay cancion o esta pausada, detener beats
    if (track == null || !track.isPlaying) {
      _scheduler.stop();
      if (_bleConnected) {
        _ble.sendCommand([0x02, 0, 0, 0, 0, 0, 0, 0]); // apagar LEDs
      }
      return;
    }

    setState(() {
      _currentTrack = track;
      _playheadMs = track.progressMs;
    });

    if (track.id != _lastTrackId) {
      _lastTrackId = track.id;
      debugPrint('Nueva cancion: ${track.name} - ${track.artist}');

      // Obtener genero via Last.fm
      final genre = await LastFmService.getArtistGenre(track.artist);
      final bpm = ReactionEngine.bpmForGenre(genre);
      final (int, int, int) color = ReactionEngine.baseColorFromGenre(genre);

      setState(() {
        _currentGenre = genre;
        _currentBpm = bpm;
      });

      // Enviar color base inmediatamente
      if (_bleConnected) {
        _ble.sendCommand(ReactionEngine.fromGenre(genre).toBytes());
      }

      // Cargar analisis de la pista
      final analysis = await _api!.getAnalysis(track.id);
      if (analysis != null) {
        setState(() => _analysis = analysis);
      }

      // Iniciar beats sinteticos
      _scheduler.stop();
      _scheduler.startSynthetic(bpm, color);
    }
  }

  Future<void> _connectBle() async {
    setState(() => _bleScanning = true);
    try {
      await _ble.connect();
    } catch (e) {
      debugPrint('BLE error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('BLE error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      setState(() => _bleScanning = false);
    }
  }

  @override
  void dispose() {
    _trackPoller?.cancel();
    _scheduler.dispose();
    _ble.dispose();
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(child: _token == null ? _buildLogin() : _buildMain()),
    );
  }

  Widget _buildLogin() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.music_note, size: 80, color: Color(0xFF1A56DB)),
          const SizedBox(height: 32),
          const Text(
            'LedCar',
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Musica inteligente para tu auto',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 48),
          _loading
              ? const CircularProgressIndicator()
              : ElevatedButton.icon(
                  onPressed: _login,
                  icon: const Icon(Icons.login),
                  label: const Text('Conectar con Spotify'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1DB954),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildMain() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          _buildNowPlaying(),
          const SizedBox(height: 24),
          _buildBleCard(),
          const SizedBox(height: 24),
          if (_analysis != null) _buildReactionModes(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'LedCar',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.logout, color: Colors.white54),
          onPressed: () async {
            _trackPoller?.cancel();
            _scheduler.stop();
            await _ble.disconnect();
            await SpotifyAuth.logout();
            setState(() {
              _token = null;
              _api = null;
              _currentTrack = null;
              _analysis = null;
              _lastTrackId = null;
            });
          },
        ),
      ],
    );
  }

  Widget _buildNowPlaying() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: _currentTrack == null
          ? const Center(
              child: Text(
                'Reproduce algo en Spotify...',
                style: TextStyle(color: Colors.white54),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.music_note, color: Color(0xFF1DB954)),
                    const SizedBox(width: 8),
                    const Text(
                      'Sonando ahora',
                      style: TextStyle(
                        color: Color(0xFF1DB954),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _currentTrack!.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _currentTrack!.artist,
                  style: const TextStyle(color: Colors.white60),
                ),
                if (_analysis != null) ...[
                  const SizedBox(height: 16),
                  _buildAnalysisRow(),
                ],
              ],
            ),
    );
  }

  Widget _buildAnalysisRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildStat(
          'Energia',
          '${(_analysis!.energy * 100).toInt()}%',
          Colors.orange,
        ),
        _buildStat(
          'Valencia',
          '${(_analysis!.valence * 100).toInt()}%',
          Colors.purple,
        ),
        _buildStat('Tempo', '${_analysis!.tempo.toInt()} BPM', Colors.blue),
        _buildStat('Beats', '${_analysis!.beats.length}', Colors.green),
      ],
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
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
                    _scheduler.stop();
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

  Widget _buildReactionModes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Modo de reaccion',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _modeChip('Energia', 'energy'),
            const SizedBox(width: 8),
            _modeChip('Valencia', 'valence'),
            const SizedBox(width: 8),
            _modeChip('Beat', 'beat'),
          ],
        ),
      ],
    );
  }

  Widget _modeChip(String label, String mode) {
    final active = _reactionMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() => _reactionMode = mode);
        if (_analysis == null) return;
        LedCommand cmd;
        switch (mode) {
          case 'energy':
            cmd = ReactionEngine.fromEnergy(_analysis!.energy);
          case 'valence':
            cmd = ReactionEngine.fromValence(_analysis!.valence);
          default:
            cmd = ReactionEngine.fromEnergy(_analysis!.energy);
        }
        _ble.sendCommand(cmd.toBytes());
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1A56DB) : const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? const Color(0xFF1A56DB) : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(color: active ? Colors.white : Colors.white54),
        ),
      ),
    );
  }
}
