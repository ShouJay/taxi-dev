import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../config/app_config.dart';
import '../models/shadow_playlist.dart';

/// MQTT 連線管理器（取代 WebSocket）
class MqttManager {
  MqttServerClient? _client;
  String deviceId;
  String brokerHost;
  final int brokerPort;

  bool _isConnected = false;
  bool _isConnecting = false;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSubscription;

  bool get isConnected => _isConnected;

  // 事件回調
  Function()? onConnected;
  Function()? onDisconnected;
  Function(DesiredPlaylist)? onDesiredPlaylist;
  Function(EmergencyState)? onEmergencyMessage;

  MqttManager({
    required this.deviceId,
    required this.brokerHost,
    this.brokerPort = AppConfig.mqttBrokerPort,
  });

  /// 連接到 EMQX Broker
  Future<void> connect() async {
    if (_isConnecting) return;
    _isConnecting = true;

    try {
      await disconnect();

      final clientId = 'taxi-app-$deviceId-${DateTime.now().millisecondsSinceEpoch}';
      final host = AppConfig.resolveMqttHost(brokerHost);

      _client = MqttServerClient.withPort(host, clientId, brokerPort);
      _client!.logging(on: false);
      _client!.keepAlivePeriod = AppConfig.mqttKeepAlive.inSeconds;
      _client!.autoReconnect = true;
      _client!.onConnected = _onConnected;
      _client!.onDisconnected = _onDisconnected;
      _client!.onAutoReconnect = () {
        print('🔄 MQTT 自動重連中...');
      };

      final connMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .startClean()
          .withWillTopic(AppConfig.statusTopic(deviceId))
          .withWillMessage(jsonEncode({'status': 'offline'}))
          .withWillQos(MqttQos.atLeastOnce);

      _client!.connectionMessage = connMessage;

      print('📡 連接 MQTT Broker: $host:$brokerPort (device: $deviceId)');
      await _client!.connect();

      if (_client!.connectionStatus?.state != MqttConnectionState.connected) {
        throw Exception(
          'MQTT 連線失敗: ${_client!.connectionStatus?.returnCode}',
        );
      }
    } catch (e) {
      print('❌ MQTT 連線錯誤: $e');
      _isConnected = false;
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  void _onConnected() {
    _isConnected = true;
    print('✅ MQTT 已連接');

    _subscribeTopics();
    _publishOnlineStatus();

    onConnected?.call();
  }

  void _onDisconnected() {
    if (!_isConnected) return;
    _isConnected = false;
    print('❌ MQTT 已斷開');
    onDisconnected?.call();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    Future.delayed(AppConfig.reconnectDelay, () {
      if (!_isConnected && !_isConnecting) {
        connect();
      }
    });
  }

  void _subscribeTopics() {
    final client = _client;
    if (client == null) return;

    client.subscribe(AppConfig.desiredTopic(deviceId), MqttQos.atLeastOnce);
    client.subscribe(AppConfig.emergencyTopic, MqttQos.atLeastOnce);

    _updatesSubscription?.cancel();
    _updatesSubscription = client.updates?.listen(_handleMessages);
    print('📥 已訂閱 desired 與 emergency topics');
  }

  void _handleMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final message in messages) {
      final topic = message.topic;
      final payload = message.payload as MqttPublishMessage;
      final body = MqttPublishPayload.bytesToStringAsString(
        payload.payload.message,
      );

      try {
        final data = jsonDecode(body) as Map<String, dynamic>;
        if (topic.endsWith('/playlist/desired')) {
          print('📋 收到 desired playlist');
          onDesiredPlaylist?.call(DesiredPlaylist.fromJson(data));
        } else if (topic == AppConfig.emergencyTopic) {
          print('🚨 收到 emergency 廣播: ${data['type']}');
          onEmergencyMessage?.call(EmergencyState.fromJson(data));
        }
      } catch (e) {
        print('❌ 解析 MQTT 訊息失敗 topic=$topic: $e');
      }
    }
  }

  /// 發送位置（QoS 0）
  void sendLocation(double latitude, double longitude) {
    if (!_isConnected || _client == null) {
      print('⚠️ MQTT 未連接，無法發送位置');
      return;
    }

    if (longitude < -180 || longitude > 180 || latitude < -90 || latitude > 90) {
      print('❌ 經緯度超出有效範圍');
      return;
    }

    final payload = jsonEncode({'lat': latitude, 'lng': longitude});
    _publish(AppConfig.locationTopic(deviceId), payload, MqttQos.atMostOnce);
  }

  /// 回報設備影子狀態（QoS 1）
  void publishReported({
    String? currentCampaignId,
    required List<LocalVideoInventory> localInventory,
    required List<ReportedError> errors,
  }) {
    if (!_isConnected || _client == null) return;

    final payload = jsonEncode({
      'current_campaign_id': currentCampaignId,
      'local_inventory': localInventory.map((e) => e.toJson()).toList(),
      'errors': errors.map((e) => e.toJson()).toList(),
    });

    _publish(AppConfig.reportedTopic(deviceId), payload, MqttQos.atLeastOnce);
  }

  void _publishOnlineStatus() {
    _publish(
      AppConfig.statusTopic(deviceId),
      jsonEncode({'status': 'online'}),
      MqttQos.atLeastOnce,
    );
  }

  void _publish(String topic, String payload, MqttQos qos) {
    final client = _client;
    if (client == null || !_isConnected) return;

    final builder = MqttClientPayloadBuilder()..addString(payload);
    client.publishMessage(topic, qos, builder.payload!);
  }

  /// 更新設備 ID 並重連
  Future<void> updateDeviceId(String newDeviceId) async {
    deviceId = newDeviceId;
    await connect();
  }

  /// 更新 Broker 位址並重連
  Future<void> updateBrokerHost(String newHost) async {
    brokerHost = newHost;
    await connect();
  }

  Future<void> disconnect() async {
    _isConnected = false;
    await _updatesSubscription?.cancel();
    _updatesSubscription = null;
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
  }

  void dispose() {
    disconnect();
  }
}
