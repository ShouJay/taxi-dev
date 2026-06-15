/// 應用程式配置
class AppConfig {
  // 後端服務地址（請根據實際環境修改）
  static const String baseUrl = 'https://robusttaxi.azurewebsites.net';
  static const String wsUrl = 'wss://robusttaxi.azurewebsites.net';

  // 🔽🔽🔽 (關鍵修正 1: 協議錯誤) 🔽🔽🔽
  // 你的本地 Python 伺服器是 http, 不是 https
  //static const String baseUrl = 'http://192.168.0.249:8080';

  // 🔽🔽🔽 (關鍵修正 2: 網址格式錯誤) 🔽🔽🔽
  // 1. 你的伺服器是 ws (不安全), 不是 wss (安全)
  // 2. 你的格式 'wss://https' 是錯誤的, 協議重複了
  //static const String wsUrl = 'ws://192.168.0.249:8080';
  // 🔼🔼🔼 修正結束 🔼🔼🔼

  // API 版本
  static const String apiVersion = 'v1';

  // API 端點
  static String get apiBaseUrl => '$baseUrl/api/$apiVersion';

  // WebSocket 配置
  static const Duration heartbeatInterval = Duration(seconds: 30);
  static const Duration locationUpdateInterval = Duration(seconds: 5);
  static const Duration reconnectDelay = Duration(seconds: 5);

  // 下載配置
  static const int defaultChunkSize = 10485760; // 10MB
  static const int maxConcurrentDownloads = 3;
  static const int downloadRetryAttempts = 3;

  // 本地儲存鍵值
  static const String deviceIdKey = 'device_id';
  static const String defaultDeviceId = 'taxi-AAB-1234-rooftop';
  static const String adminModeKey = 'admin_mode';

  /// 使用者是否啟用循環播放（出廠未設定時，僅在本地有影片時預設為啟用）
  static const String playbackEnabledKey = 'playback_enabled';

  // 播放配置
  static const int tapCountToSettings = 5;
  static const Duration tapDetectionWindow = Duration(seconds: 3);
}
