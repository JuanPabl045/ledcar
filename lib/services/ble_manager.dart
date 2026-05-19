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
  int _txCount = 0;
  int _lastTxLogMs = 0;

  // Write guard: prevents BLE backpressure buildup.
  // Only 1 write in flight at a time; latest command always wins.
  bool _writeInFlight = false;
  List<int>? _pendingWrite;

  bool get isConnected => _device != null && (_device?.isConnected ?? false);

  StreamSubscription? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
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

        _connSub?.cancel();
        _connSub = _device!.connectionState.listen((state) {
          if (state == BluetoothConnectionState.disconnected) {
            _char = null;
            _device = null;
            _connectionController.add(false);
            debugPrint('BLE: desconectado (evento GATT)');
          }
        });

        final hasChar = await _discoverCharacteristic();
        if (!hasChar) {
          debugPrint('BLE: no se encontro caracteristica, cerrando conexion');
          await disconnect();
          throw Exception('Caracteristica BLE no encontrada');
        }
        // Request high-priority connection (7.5ms interval instead of 30ms)
        await _device!.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
        await _measureLatency();

        // Probe write: verifies that commands can actually reach firmware.
        await sendCommand([0x01, 12, 12, 24, 12, 0, 0, 0]);
        debugPrint('BLE: probe enviado');

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

  Future<bool> _discoverCharacteristic() async {
    final services = await _device!.discoverServices();
    final svcTarget = _svcUuid.toLowerCase();
    final chrTarget = _charUuid.toLowerCase();
    for (final s in services) {
      if (s.serviceUuid.toString().toLowerCase() == svcTarget) {
        for (final c in s.characteristics) {
          if (c.characteristicUuid.toString().toLowerCase() == chrTarget) {
            _char = c;
            debugPrint('BLE: caracteristica encontrada');
            return true;
          }
        }
      }
    }
    debugPrint('BLE: caracteristica NO encontrada — verifica los UUIDs');
    return false;
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
    if (!isConnected) return;
    if (_char == null) {
      final recovered = await _discoverCharacteristic();
      if (!recovered) return;
    }
    if (_char == null) return;

    // Latest-wins: si ya hay un write en vuelo, solo guardar el más reciente.
    if (_writeInFlight) {
      _pendingWrite = bytes;
      return;
    }

    _writeInFlight = true;
    await _doWrite(bytes);

    // Después del write, enviar el comando pendiente más reciente (si existe).
    while (_pendingWrite != null) {
      final next = _pendingWrite!;
      _pendingWrite = null;
      await _doWrite(next);
    }
    _writeInFlight = false;
  }

  Future<void> _doWrite(List<int> bytes) async {
    try {
      await _char!.write(bytes, withoutResponse: true);
      _txCount++;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_txCount % 50 == 0 || (nowMs - _lastTxLogMs) > 2000) {
        _lastTxLogMs = nowMs;
        final br = bytes.length >= 5 ? bytes[4] : -1;
        debugPrint('BLE: TX ok x$_txCount (br=$br)');
      }
    } catch (e) {
      debugPrint('BLE: write error: $e');
      try {
        await _char!.write(bytes, withoutResponse: false);
        _txCount++;
      } catch (e2) {
        debugPrint('BLE: fallback write error: $e2');
      }
    }
  }

  Future<void> disconnect() async {
    _bleScanning = false;
    await _connSub?.cancel();
    _connSub = null;
    await _device?.disconnect();
    _device = null;
    _char = null;
    _connectionController.add(false);
    debugPrint('BLE: desconectado');
  }

  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _connectionController.close();
  }
}
