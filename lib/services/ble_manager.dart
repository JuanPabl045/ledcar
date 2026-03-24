import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleManager {
  static const _deviceName = 'LedCar';
  static const _svcUuid = '12345678-1234-1234-1234-123456789abc';
  static const _charUuid = 'abcdefab-cdef-abcd-efab-cdefabcdefab';

  BluetoothDevice? _device;
  BluetoothCharacteristic? _char;
  int measuredLatencyMs = 40;
  bool _bleScanning = false;

  bool get isConnected => _device != null && (_device?.isConnected ?? false);

  StreamSubscription? _scanSub;
  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;

  Future<void> connect() async {
    if (_bleScanning || isConnected) return;
    _bleScanning = true;
    debugPrint('BLE: iniciando scan...');

    try {
      await FlutterBluePlus.startScan(
        withNames: [_deviceName],
        timeout: const Duration(seconds: 15),
      );

      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        if (results.isEmpty) return;

        final result = results.first;
        debugPrint('BLE: encontrado ${result.device.platformName}');

        await FlutterBluePlus.stopScan();
        _scanSub?.cancel();

        _device = result.device;
        await _device!.connect(autoConnect: false);
        debugPrint('BLE: conectado');

        await _discoverCharacteristic();
        await _measureLatency();

        _bleScanning = false;
        _connectionController.add(true);
      });

      // Si el timeout expira sin encontrar el dispositivo
      await Future.delayed(const Duration(seconds: 16));
      if (!isConnected) {
        _bleScanning = false;
        debugPrint('BLE: timeout — dispositivo no encontrado');
      }
    } catch (e) {
      _bleScanning = false;
      debugPrint('BLE: error en scan: $e');
      rethrow;
    }
  }

  Future<void> _discoverCharacteristic() async {
    final services = await _device!.discoverServices();
    for (final s in services) {
      if (s.serviceUuid.toString() == _svcUuid) {
        for (final c in s.characteristics) {
          if (c.characteristicUuid.toString() == _charUuid) {
            _char = c;
            debugPrint('BLE: caracteristica encontrada');
            return;
          }
        }
      }
    }
    debugPrint('BLE: caracteristica NO encontrada — verifica los UUIDs');
  }

  Future<void> _measureLatency() async {
    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      await _device!.readRssi();
      final rtt = DateTime.now().millisecondsSinceEpoch - t0;
      measuredLatencyMs = (rtt / 2).round().clamp(10, 100);
      debugPrint('BLE: latencia medida = ${measuredLatencyMs}ms');
    } catch (e) {
      debugPrint('BLE: no se pudo medir latencia, usando default 40ms');
    }
  }

  Future<void> sendCommand(List<int> bytes) async {
    if (_char == null) {
      debugPrint('BLE: sin caracteristica, comando descartado');
      return;
    }
    try {
      await _char!.write(bytes, withoutResponse: false);
    } catch (e) {
      debugPrint('BLE: error enviando comando: $e');
    }
  }

  Future<void> disconnect() async {
    _bleScanning = false;
    await _device?.disconnect();
    _device = null;
    _char = null;
    _connectionController.add(false);
    debugPrint('BLE: desconectado');
  }

  void dispose() {
    _scanSub?.cancel();
    _connectionController.close();
  }
}
