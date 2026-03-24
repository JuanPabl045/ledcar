import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'spotify_auth.dart';

class Beat {
  final double start;
  final double duration;
  final double confidence;

  Beat({required this.start, required this.duration, required this.confidence});

  factory Beat.fromJson(Map<String, dynamic> j) => Beat(
    start: j['start'].toDouble(),
    duration: j['duration'].toDouble(),
    confidence: j['confidence'].toDouble(),
  );
}

class TrackAnalysis {
  final List<Beat> beats;
  final double tempo;
  final double energy;
  final double valence;
  final double danceability;

  TrackAnalysis({
    required this.beats,
    required this.tempo,
    required this.energy,
    required this.valence,
    required this.danceability,
  });
}

class CurrentTrack {
  final String id;
  final String name;
  final String artist;
  final int progressMs;
  final bool isPlaying;

  CurrentTrack({
    required this.id,
    required this.name,
    required this.artist,
    required this.progressMs,
    required this.isPlaying,
  });
}

class SpotifyApiService {
  String token;
  SpotifyApiService(this.token);

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  Future<T?> _handleRequest<T>(
    Future<http.Response> Function(String token) request,
    T? Function(http.Response) onSuccess,
  ) async {
    var response = await request(token);

    // Si es 401, intenta refrescar el token
    if (response.statusCode == 401) {
      debugPrint('Token expired, attempting refresh...');
      final newToken = await SpotifyAuth.refreshToken();

      if (newToken != null) {
        token = newToken;
        response = await request(token);
      } else {
        debugPrint('Failed to refresh token');
        return null;
      }
    }

    if (response.statusCode == 204 || response.body.isEmpty) return null;

    if (response.statusCode == 200) {
      return onSuccess(response);
    }

    debugPrint('Request error: ${response.statusCode} ${response.body}');
    return null;
  }

  // Cancion que esta sonando ahora mismo
  Future<CurrentTrack?> getCurrentTrack() async {
    return _handleRequest<CurrentTrack?>(
      (token) => http.get(
        Uri.parse('https://api.spotify.com/v1/me/player/currently-playing'),
        headers: _headers,
      ),
      (response) {
        final json = jsonDecode(response.body);
        final item = json['item'];
        if (item == null) return null;

        return CurrentTrack(
          id: item['id'],
          name: item['name'],
          artist: item['artists'][0]['name'],
          progressMs: json['progress_ms'] ?? 0,
          isPlaying: json['is_playing'] ?? false,
        );
      },
    );
  }

  // Beats exactos y datos de la pista
  Future<TrackAnalysis?> getAnalysis(String trackId) async {
    // Llamadas en paralelo para no esperar una por una
    final results = await Future.wait([
      http.get(
        Uri.parse('https://api.spotify.com/v1/audio-analysis/$trackId'),
        headers: _headers,
      ),
      http.get(
        Uri.parse('https://api.spotify.com/v1/audio-features/$trackId'),
        headers: _headers,
      ),
    ]);

    var analysisRes = results[0];
    var featuresRes = results[1];

    // Si alguno es 401, refrescar token e intentar de nuevo
    if (analysisRes.statusCode == 401 || featuresRes.statusCode == 401) {
      debugPrint('Token expired in analysis, attempting refresh...');
      final newToken = await SpotifyAuth.refreshToken();

      if (newToken != null) {
        token = newToken;
        final retryResults = await Future.wait([
          http.get(
            Uri.parse('https://api.spotify.com/v1/audio-analysis/$trackId'),
            headers: _headers,
          ),
          http.get(
            Uri.parse('https://api.spotify.com/v1/audio-features/$trackId'),
            headers: _headers,
          ),
        ]);
        analysisRes = retryResults[0];
        featuresRes = retryResults[1];
      }
    }

    if (analysisRes.statusCode != 200 || featuresRes.statusCode != 200) {
      debugPrint(
        'Analysis error: ${analysisRes.statusCode} ${analysisRes.body}',
      );
      debugPrint(
        'Features error: ${featuresRes.statusCode} ${featuresRes.body}',
      );
      return null;
    }

    final aJson = jsonDecode(analysisRes.body);
    final fJson = jsonDecode(featuresRes.body);

    // Filtrar beats con baja confianza
    final beats = (aJson['beats'] as List)
        .map((b) => Beat.fromJson(b))
        .where((b) => b.confidence > 0.4)
        .toList();

    return TrackAnalysis(
      beats: beats,
      tempo: fJson['tempo']?.toDouble() ?? 120.0,
      energy: fJson['energy']?.toDouble() ?? 0.5,
      valence: fJson['valence']?.toDouble() ?? 0.5,
      danceability: fJson['danceability']?.toDouble() ?? 0.5,
    );
  }
}
