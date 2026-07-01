import 'dart:io';

/// 應用程式配置
class AppConfig {
  // HTTP API（影片分片下載）
  static const String baseUrl = 'https://huge-guests-teach.loca.lt';

  // 本地 Docker 開發（Android 模擬器請用 10.0.2.2）
  // static const String baseUrl = 'http://10.0.2.2:8080';

  // MQTT Broker（EMQX，預設 1883）
  static const String mqttBrokerHost = '0.tcp.jp.ngrok.io';
  static const int mqttBrokerPort = 28806;

  // 實體機連本地 Docker 時改為主機 IP，例如：
  // static const String mqttBrokerHost = '192.168.0.249';

  static String get apiHost {
    final uri = Uri.parse(baseUrl);
    return uri.host;
  }

  static String resolveMqttHost(String configuredHost) {
    if (Platform.isAndroid && configuredHost == 'localhost') {
      return '10.0.2.2';
    }
    return configuredHost;
  }

  // API 版本
  static const String apiVersion = 'v1';

  static String get apiBaseUrl => '$baseUrl/api/$apiVersion';

  // MQTT Topic 前綴
  static String locationTopic(String deviceId) => 'taxi/$deviceId/location';
  static String desiredTopic(String deviceId) =>
      'taxi/$deviceId/playlist/desired';
  static String reportedTopic(String deviceId) =>
      'taxi/$deviceId/playlist/reported';
  static String statusTopic(String deviceId) => 'taxi/$deviceId/status';
  static const String emergencyTopic = 'taxi/all/emergency';

  // 連線配置
  static const Duration locationUpdateInterval = Duration(seconds: 5);
  static const Duration reconnectDelay = Duration(seconds: 5);
  static const Duration mqttKeepAlive = Duration(seconds: 60);

  // 下載配置
  static const int defaultChunkSize = 10485760; // 10MB
  static const int maxConcurrentDownloads = 3;
  static const int downloadRetryAttempts = 3;

  // 本地儲存鍵值
  static const String deviceIdKey = 'device_id';
  static const String defaultDeviceId = 'taxi-AAB-1234-rooftop';
  static const String adminModeKey = 'admin_mode';
  static const String mqttBrokerHostKey = 'mqtt_broker_host';
  static const String deviceRoleKey = 'device_role';
  static const String defaultDeviceRole = 'SCREEN_A';

  /// 使用者是否啟用循環播放
  static const String playbackEnabledKey = 'playback_enabled';

  // 播放配置
  static const int tapCountToSettings = 5;
  static const Duration tapDetectionWindow = Duration(seconds: 3);
}
