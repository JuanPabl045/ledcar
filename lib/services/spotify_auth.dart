import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class SpotifyAuth {
  static const _clientId = '41a7a97b2d6e42028b56b15a723c5c61';
  static const _redirectUri = 'ledcar://callback';
  static const _scopes = 'user-read-playback-state user-read-currently-playing';
  static const _storage = FlutterSecureStorage();

  static String _generateVerifier() {
    final r = Random.secure();
    final b = List<int>.generate(32, (_) => r.nextInt(256));
    return base64UrlEncode(b).replaceAll('=', '');
  }

  static String _generateChallenge(String verifier) {
    final d = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(d.bytes).replaceAll('=', '');
  }

  static Future<String?> login() async {
    final verifier = _generateVerifier();
    final challenge = _generateChallenge(verifier);

    final authUrl = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': _clientId,
      'response_type': 'code',
      'redirect_uri': _redirectUri,
      'scope': _scopes,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
    });

    debugPrint('AUTH URL: ${authUrl.toString()}');

    String result;
    try {
      result = await FlutterWebAuth2.authenticate(
        url: authUrl.toString(),
        callbackUrlScheme: 'ledcar',
        options: const FlutterWebAuth2Options(
          preferEphemeral: false,
          intentFlags: ephemeralIntentFlags,
        ),
      );
      debugPrint('AUTH RESULT: $result');
    } catch (e) {
      debugPrint('AUTH ERROR: $e');
      rethrow;
    }

    final code = Uri.parse(result).queryParameters['code'];
    if (code == null) throw Exception('No se recibio codigo');

    final response = await http.post(
      Uri.parse('https://accounts.spotify.com/api/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': _redirectUri,
        'client_id': _clientId,
        'code_verifier': verifier,
      },
    );

    debugPrint('Token response: ${response.statusCode} ${response.body}');

    if (response.statusCode != 200) {
      throw Exception('Token error ${response.statusCode}: ${response.body}');
    }

    final json = jsonDecode(response.body);
    final token = json['access_token'] as String;
    final refresh = json['refresh_token'] as String? ?? '';

    await _storage.write(key: 'spotify_token', value: token);
    await _storage.write(key: 'spotify_refresh', value: refresh);
    return token;
  }

  static Future<String?> getToken() => _storage.read(key: 'spotify_token');

  static Future<String?> refreshToken() async {
    final refresh = await _storage.read(key: 'spotify_refresh');
    if (refresh == null) {
      debugPrint('No refresh token available');
      return null;
    }

    try {
      final response = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
          'client_id': _clientId,
        },
      );

      debugPrint('Refresh token response: ${response.statusCode}');

      if (response.statusCode != 200) {
        debugPrint('Refresh token error: ${response.body}');
        return null;
      }

      final json = jsonDecode(response.body);
      final token = json['access_token'] as String;

      // Guardar el nuevo token
      await _storage.write(key: 'spotify_token', value: token);

      // Si hay nuevo refresh token, actualizarlo
      if (json.containsKey('refresh_token')) {
        final newRefresh = json['refresh_token'] as String;
        await _storage.write(key: 'spotify_refresh', value: newRefresh);
      }

      return token;
    } catch (e) {
      debugPrint('Exception refreshing token: $e');
      return null;
    }
  }

  static Future<void> logout() async {
    await _storage.delete(key: 'spotify_token');
    await _storage.delete(key: 'spotify_refresh');
  }
}
