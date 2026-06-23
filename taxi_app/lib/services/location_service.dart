import 'dart:async';
import 'package:geolocator/geolocator.dart';
import '../services/mqtt_manager.dart';
import '../config/app_config.dart';

/// GPS 定位服務 — 透過 MQTT 上報位置
class LocationService {
  final MqttManager mqttManager;
  Timer? _locationTimer;
  Position? _currentPosition;
  bool _isRunning = false;
  StreamSubscription<Position>? _positionSubscription;

  DateTime? _lastLocationSentTime;
  int _sentCount = 0;

  Function(Position)? onLocationUpdate;
  Function(String)? onError;

  LocationService({required this.mqttManager});

  Position? get currentPosition => _currentPosition;
  bool get isRunning => _isRunning;
  DateTime? get lastLocationSentTime => _lastLocationSentTime;
  int get sentCount => _sentCount;

  String getLocationAckStatus() {
    if (_lastLocationSentTime == null) return '尚未發送位置';
    if (!mqttManager.isConnected) return 'MQTT 未連接';
    final duration = DateTime.now().difference(_lastLocationSentTime!);
    return '✅ 已發送 (${_durationToString(duration)}前)';
  }

  String _durationToString(Duration duration) {
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}分${duration.inSeconds % 60}秒';
    }
    return '${duration.inSeconds}秒';
  }

  Future<bool> start() async {
    if (_isRunning) return true;

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        onError?.call('位置服務未啟用');
        return false;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          onError?.call('位置權限被拒絕');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        onError?.call('位置權限被永久拒絕');
        return false;
      }

      _isRunning = true;

      try {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) {
          _currentPosition = lastKnown;
          _sendLocationUpdate(lastKnown);
          onLocationUpdate?.call(lastKnown);
        } else {
          await _getCurrentLocation();
        }
      } catch (_) {
        await _getCurrentLocation();
      }

      _startLocationStream();

      if (_locationTimer == null) {
        _restartLocationTimer();
      }

      return true;
    } catch (e) {
      _isRunning = false;
      onError?.call('啟動位置服務失敗: $e');
      return false;
    }
  }

  void stop() {
    _locationTimer?.cancel();
    _locationTimer = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _isRunning = false;
  }

  Future<void> _getCurrentLocation() async {
    try {
      _currentPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (_currentPosition != null) {
        _sendLocationUpdate(_currentPosition!);
        onLocationUpdate?.call(_currentPosition!);
      }
    } catch (e) {
      onError?.call('獲取位置失敗: $e');
    }
  }

  void _restartLocationTimer() {
    _locationTimer?.cancel();
    _locationTimer = Timer(AppConfig.locationUpdateInterval, () {
      if (_currentPosition != null) {
        _sendLocationUpdate(_currentPosition!);
      } else {
        _getCurrentLocation();
      }
    });
  }

  void _startLocationStream() {
    _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(
      (position) {
        _currentPosition = position;
        _sendLocationUpdate(position);
        onLocationUpdate?.call(position);
      },
      onError: (error) {
        onError?.call('位置監聽錯誤: $error');
      },
    );
  }

  void _sendLocationUpdate(Position position) {
    _lastLocationSentTime = DateTime.now();
    _sentCount++;
    mqttManager.sendLocation(position.latitude, position.longitude);
    _restartLocationTimer();
  }

  Future<void> sendCurrentLocation() async {
    if (_currentPosition != null) {
      _sendLocationUpdate(_currentPosition!);
    } else {
      await _getCurrentLocation();
    }
  }

  String getLocationInfo() {
    if (_currentPosition == null) return '位置未知';
    return '緯度: ${_currentPosition!.latitude.toStringAsFixed(6)}\n'
        '經度: ${_currentPosition!.longitude.toStringAsFixed(6)}\n'
        '精度: ${_currentPosition!.accuracy.toStringAsFixed(0)} 米';
  }

  void dispose() => stop();
}
