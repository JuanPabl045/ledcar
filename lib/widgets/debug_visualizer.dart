import 'dart:collection';
import 'package:flutter/material.dart';

class DebugData {
  final double si;
  final double tension;
  final double drumEnv;
  final double drive;
  final int dt;

  DebugData({
    required this.si,
    required this.tension,
    required this.drumEnv,
    required this.drive,
    this.dt = 0,
  });
}

class DebugVisualizer extends StatefulWidget {
  final ValueNotifier<DebugData> notifier;

  const DebugVisualizer({Key? key, required this.notifier}) : super(key: key);

  @override
  State<DebugVisualizer> createState() => _DebugVisualizerState();
}

class _DebugVisualizerState extends State<DebugVisualizer> {
  final Queue<DebugData> _history = Queue<DebugData>();
  static const int _maxHistory = 150; // Alrededor de 3.5 segundos a 40 fps

  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_onNewData);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_onNewData);
    super.dispose();
  }

  void _onNewData() {
    setState(() {
      if (_history.length >= _maxHistory) {
        _history.removeFirst();
      }
      _history.add(widget.notifier.value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF101018), // Fondo muy oscuro
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Stack(
        children: [
          CustomPaint(
            size: Size.infinite,
            painter: _OscilloscopePainter(history: _history.toList(), maxHistory: _maxHistory),
          ),
          Positioned(
            top: 4,
            left: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Legend(color: Colors.white, text: 'Sustained (si)'),
                _Legend(color: Colors.blueAccent, text: 'Tension'),
                _Legend(color: Colors.orangeAccent, text: 'Drum Env'),
                _Legend(color: Colors.redAccent, text: 'Drive (Luz)'),
              ],
            ),
          ),
          Positioned(
            top: 4,
            right: 6,
            child: _history.isNotEmpty
                ? Text(
                    'DT: ${_history.last.dt} ms',
                    style: TextStyle(
                      color: _history.last.dt > 40 ? Colors.red : Colors.greenAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String text;

  const _Legend({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(width: 8, height: 8, color: color),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: Colors.white70, fontSize: 10)),
        ],
      ),
    );
  }
}

class _OscilloscopePainter extends CustomPainter {
  final List<DebugData> history;
  final int maxHistory;

  _OscilloscopePainter({required this.history, required this.maxHistory});

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;

    final double stepX = size.width / (maxHistory - 1);

    final paintSi = Paint()..color = Colors.white.withOpacity(0.5)..style = PaintingStyle.stroke..strokeWidth = 2;
    final paintTension = Paint()..color = Colors.blueAccent..style = PaintingStyle.stroke..strokeWidth = 2;
    final paintDrum = Paint()..color = Colors.orangeAccent..style = PaintingStyle.stroke..strokeWidth = 2;
    final paintDrive = Paint()..color = Colors.redAccent..style = PaintingStyle.stroke..strokeWidth = 2;

    final pathSi = Path();
    final pathTension = Path();
    final pathDrum = Path();
    final pathDrive = Path();

    // Las nuevas lecturas entran por la derecha.
    // Calculamos el desfase X inicial si la cola no está llena
    final double startX = size.width - (history.length - 1) * stepX;

    for (int i = 0; i < history.length; i++) {
      final data = history[i];
      final x = startX + i * stepX;
      
      // Escalar la gráfica para que el "techo" de la pantalla represente 1.5 en lugar de 1.0
      // Esto evita que se vea cortado (clipping) si los valores superan 1.0
      final double maxScale = 1.5;
      final ySi = size.height - ((data.si / maxScale).clamp(0.0, 1.0) * size.height);
      final yTension = size.height - ((data.tension / maxScale).clamp(0.0, 1.0) * size.height);
      final yDrum = size.height - ((data.drumEnv / maxScale).clamp(0.0, 1.0) * size.height);
      final yDrive = size.height - ((data.drive / maxScale).clamp(0.0, 1.0) * size.height);

      if (i == 0) {
        pathSi.moveTo(x, ySi);
        pathTension.moveTo(x, yTension);
        pathDrum.moveTo(x, yDrum);
        pathDrive.moveTo(x, yDrive);
      } else {
        pathSi.lineTo(x, ySi);
        pathTension.lineTo(x, yTension);
        pathDrum.lineTo(x, yDrum);
        pathDrive.lineTo(x, yDrive);
      }
    }

    canvas.drawPath(pathSi, paintSi);
    canvas.drawPath(pathTension, paintTension);
    canvas.drawPath(pathDrum, paintDrum);
    canvas.drawPath(pathDrive, paintDrive);
  }

  @override
  bool shouldRepaint(covariant _OscilloscopePainter oldDelegate) {
    return true;
  }
}
