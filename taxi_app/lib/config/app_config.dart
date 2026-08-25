import 'dart:io';

/// 應用程式配置
class AppConfig {
  static const String environment = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'development',
  );
  static const String _configuredBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
  );
  static const String _configuredMqttHost = String.fromEnvironment('MQTT_HOST');
  static const int _configuredMqttPort = int.fromEnvironment(
    'MQTT_PORT',
    defaultValue: 0,
  );
  static const bool mqttUseTls = bool.fromEnvironment(
    'MQTT_USE_TLS',
    defaultValue: false,
  );
  static const String mqttUsername = String.fromEnvironment('MQTT_USERNAME');
  static const String mqttPassword = String.fromEnvironment('MQTT_PASSWORD');

  static String get baseUrl {
    if (_configuredBaseUrl.isNotEmpty) return _configuredBaseUrl;
    if (environment == 'development') return 'http://10.0.2.2:8080';
    throw StateError('$environment 建置必須設定 API_BASE_URL');
  }

  static String get mqttBrokerHost {
    if (_configuredMqttHost.isNotEmpty) return _configuredMqttHost;
    if (environment == 'development') return '10.0.2.2';
    throw StateError('$environment 建置必須設定 MQTT_HOST');
  }

  static int get mqttBrokerPort {
    if (_configuredMqttPort > 0) return _configuredMqttPort;
    if (environment == 'development') return 1883;
    throw StateError('$environment 建置必須設定 MQTT_PORT');
  }

  static void validate() {
    final apiUri = Uri.parse(baseUrl);
    final mqttHost = mqttBrokerHost;
    mqttBrokerPort;
    if (environment == 'production') {
      const forbiddenHosts = {'localhost', '127.0.0.1', '10.0.2.2'};
      if (apiUri.scheme != 'https' || forbiddenHosts.contains(apiUri.host)) {
        throw StateError('production API_BASE_URL 必須使用非本機 HTTPS');
      }
      if (forbiddenHosts.contains(mqttHost) ||
          !mqttUseTls ||
          mqttUsername.isEmpty ||
          mqttPassword.isEmpty) {
        throw StateError('production MQTT 必須使用非本機 TLS Broker 與身分驗證');
      }
    }
  }

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
