import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class LastFmService {
  static const _apiKey = '68a17ac454ffd85463e593535c153afc';
  static const _baseUrl = 'https://ws.audioscrobbler.com/2.0/';

  // Obtener genero del artista
  static Future<String> getArtistGenre(String artist) async {
    try {
      final url = Uri.parse(_baseUrl).replace(queryParameters: {
        'method': 'artist.getinfo',
        'artist': artist,
        'api_key': _apiKey,
        'format': 'json',
      });

      final res = await http.get(url);
      if (res.statusCode != 200) return 'default';

      final json = jsonDecode(res.body);
      final tags = json['artist']?['tags']?['tag'] as List?;
      if (tags == null || tags.isEmpty) return 'default';

      // El primer tag es el genero principal
      final genre = tags.first['name'].toString().toLowerCase();
      debugPrint('LastFM genre para $artist: $genre');
      return genre;
    } catch (e) {
      debugPrint('LastFM error: $e');
      return 'default';
    }
  }
}
