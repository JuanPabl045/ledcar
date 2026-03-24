class LedCommand {
  final int tipo;
  final int r;
  final int g;
  final int b;
  final int brillo;
  final int patron;
  final int offsetMs;

  const LedCommand({
    required this.tipo,
    required this.r,
    required this.g,
    required this.b,
    required this.brillo,
    required this.patron,
    this.offsetMs = 0,
  });

  List<int> toBytes() {
    final hi = (offsetMs >> 8) & 0xFF;
    final lo = offsetMs & 0xFF;
    return <int>[
      tipo & 0xFF,
      r.clamp(0, 255),
      g.clamp(0, 255),
      b.clamp(0, 255),
      brillo.clamp(0, 255),
      patron.clamp(0, 255),
      hi,
      lo,
    ];
  }
}

class ReactionEngine {
  static (int, int, int) baseColor(double energy, double valence) {
    final safeEnergy = energy.clamp(0.0, 1.0);
    final safeValence = valence.clamp(0.0, 1.0);

    final r = (120 + 135 * safeEnergy).round();
    final g = (40 + 180 * safeValence).round();
    final b = (255 - 140 * safeEnergy).round();
    return (r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
  }

  static LedCommand fromEnergy(double energy) {
    final e = energy.clamp(0.0, 1.0);
    final color = baseColor(e, 0.5);
    final brightness = (80 + e * 175).round().clamp(0, 255);
    final pattern = e > 0.75
        ? 4
        : e > 0.45
        ? 3
        : 2;
    return LedCommand(
      tipo: 0x01,
      r: color.$1,
      g: color.$2,
      b: color.$3,
      brillo: brightness,
      patron: pattern,
    );
  }

  static LedCommand fromValence(double valence) {
    final v = valence.clamp(0.0, 1.0);
    final r = (40 + 200 * v).round().clamp(0, 255);
    final g = (60 + 180 * v).round().clamp(0, 255);
    final b = (220 - 170 * v).round().clamp(0, 255);
    final brightness = (110 + 120 * v).round().clamp(0, 255);

    return LedCommand(
      tipo: 0x01,
      r: r,
      g: g,
      b: b,
      brillo: brightness,
      patron: v > 0.5 ? 1 : 2,
    );
  }

  // BPM tipico por genero
  static const _genreBpm = {
    'rock': 128,
    'metal': 160,
    'electronic': 135,
    'techno': 140,
    'house': 125,
    'pop': 120,
    'jazz': 95,
    'classical': 80,
    'hiphop': 90,
    'rap': 90,
    'latin': 110,
    'reggae': 80,
    'blues': 75,
    'country': 100,
    'default': 110,
  };

  static int bpmForGenre(String genre) {
    final key = _genreBpm.keys.firstWhere(
      (k) => genre.toLowerCase().contains(k),
      orElse: () => 'default',
    );
    return _genreBpm[key]!;
  }

  // Intervalo entre beats en ms
  static int beatIntervalMs(int bpm) => (60000 / bpm).round();

  // Colores base por genero (r, g, b)
  static const Map<String, (int, int, int)> _palettes = {
    'rock': (220, 40, 20),
    'metal': (180, 0, 0),
    'electronic': (0, 200, 255),
    'techno': (60, 0, 255),
    'house': (255, 80, 200),
    'pop': (255, 180, 0),
    'jazz': (30, 100, 200),
    'classical': (180, 220, 255),
    'hiphop': (80, 0, 180),
    'rap': (100, 0, 160),
    'latin': (255, 120, 0),
    'reggae': (0, 180, 60),
    'blues': (0, 80, 200),
    'country': (200, 160, 40),
    'default': (100, 100, 255),
  };

  static (int, int, int) baseColorFromGenre(String genre) {
    final key = _palettes.keys.firstWhere(
      (k) => genre.toLowerCase().contains(k),
      orElse: () => 'default',
    );
    return _palettes[key]!;
  }

  static LedCommand fromGenre(String genre) {
    final color = baseColorFromGenre(genre);
    final bpm = bpmForGenre(genre);
    final brightness =
        (bpm > 130
                ? 255
                : bpm > 100
                ? 200
                : 160)
            .clamp(0, 255);
    final pattern = bpm > 130
        ? 4
        : bpm > 100
        ? 3
        : 2;
    return LedCommand(
      tipo: 0x01,
      r: color.$1,
      g: color.$2,
      b: color.$3,
      brillo: brightness,
      patron: pattern,
    );
  }
}
