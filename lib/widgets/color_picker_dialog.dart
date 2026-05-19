import 'package:flutter/material.dart';

class ColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  final void Function(Color) onColorSelected;

  const ColorPickerDialog({
    super.key,
    required this.initialColor,
    required this.onColorSelected,
  });

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  double _hue = 0;
  double _saturation = 1.0;
  double _value = 0.3; // Oscuro por defecto

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(widget.initialColor);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value.clamp(0.0, 0.5); // Limitar a colores oscuros
  }

  @override
  Widget build(BuildContext context) {
    final color = HSVColor.fromAHSV(1.0, _hue, _saturation, _value).toColor();
    return AlertDialog(
      title: const Text('Selecciona un color (oscuro)'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
          const SizedBox(height: 16),
          Slider(
            value: _hue,
            min: 0,
            max: 360,
            label: 'Tono',
            onChanged: (v) => setState(() => _hue = v),
          ),
          Slider(
            value: _saturation,
            min: 0.5,
            max: 1.0,
            label: 'Saturación',
            onChanged: (v) => setState(() => _saturation = v),
          ),
          Slider(
            value: _value,
            min: 0.05,
            max: 0.5,
            label: 'Brillo',
            onChanged: (v) => setState(() => _value = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onColorSelected(color);
            Navigator.of(context).pop();
          },
          child: const Text('Aplicar'),
        ),
      ],
    );
  }
}
