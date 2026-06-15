# Docker 網絡連接問題解決指南

## 問題描述

Flutter App 無法連接到運行在 Docker 容器中的後端服務，出現 "Connection timeout" 錯誤。

## 問題原因

1. **Docker 網絡隔離**：容器運行在 Docker 網絡中，與主機網絡隔離
2. **localhost 解析問題**：Flutter App 中的 `localhost` 指向設備本身，不是主機
3. **端口映射配置**：需要正確配置 Docker 端口映射

## 解決方案

### 方案 1：使用主機 IP 地址（推薦）

#### 1. 獲取主機 IP 地址

```bash
# macOS/Linux
ifconfig | grep "inet " | grep -v 127.0.0.1

# Windows
ipconfig | findstr "IPv4"
```

#### 2. 更新 Flutter API 客戶端配置

在 `flutter_api_client.dart` 中修改 `ServerConfig` 類別：

```dart
class ServerConfig {
  // 替換為您的主機 IP 地址
  static const String dockerHost = '192.168.0.103';  // 您的主機 IP
  static const int dockerPort = 8080;
  
  static String get host {
    if (Platform.isAndroid) {
      return dockerHost;  // Android 使用主機 IP
    } else if (Platform.isIOS) {
      return localHost;   // iOS 可以使用 localhost
    } else {
      return dockerHost;  // 其他平台使用主機 IP
    }
  }
}
```

#### 3. 測試連接

```bash
# 測試 HTTP 連接
curl http://192.168.0.103:8080/health

# 測試 Socket.IO 連接
curl http://192.168.0.103:8080/socket.io/
```

### 方案 2：配置 Docker 網絡模式

#### 1. 使用 host 網絡模式

修改 `docker-compose.yml`：

```yaml
version: '3.8'
services:
  smart_taxi_service:
    build: .
    network_mode: "host"  # 使用主機網絡
    depends_on:
      - smart_taxi_mongodb
    environment:
      - MONGODB_URI=mongodb://localhost:27017/smart_taxi_db

  smart_taxi_mongodb:
    image: mongo:7.0
    network_mode: "host"  # 使用主機網絡
    volumes:
      - mongodb_data:/data/db

volumes:
  mongodb_data:
```

#### 2. 重新啟動服務

```bash
docker-compose down
docker-compose up -d
```

### 方案 3：使用 Docker Desktop 的網絡配置

#### 1. 檢查 Docker Desktop 設置

- 打開 Docker Desktop
- 進入 Settings > Resources > Network
- 確保 "Enable Kubernetes" 未勾選（如果不需要）

#### 2. 使用 Docker 內部 IP

```bash
# 獲取容器 IP
docker inspect smart_taxi_service | grep IPAddress

# 使用容器 IP 連接
curl http://172.17.0.2:8080/health
```

## 診斷步驟

### 1. 檢查 Docker 容器狀態

```bash
docker ps
```

確保容器狀態為 "Up" 且端口映射正確。

### 2. 檢查端口映射

```bash
docker port smart_taxi_service
```

應該顯示：`8080/tcp -> 0.0.0.0:8080`

### 3. 測試主機連接

```bash
# 測試本地連接
curl http://localhost:8080/health

# 測試主機 IP 連接
curl http://192.168.0.103:8080/health
```

### 4. 檢查容器日誌

```bash
docker logs smart_taxi_service --tail 20
```

### 5. 檢查網絡連接

```bash
# 檢查端口是否監聽
netstat -tlnp | grep 8080

# 檢查防火牆設置
sudo ufw status
```

## Flutter App 配置

### 1. 更新 API 客戶端

使用更新後的 `flutter_api_client.dart`，它包含：

- 自動環境檢測
- Docker 網絡配置
- 連接超時處理
- 錯誤重試機制

### 2. 測試連接

```dart
// 測試服務器連接
final available = await TaxiAdHttpClient.testConnection();
if (available) {
  print('服務器連接正常');
} else {
  print('服務器連接失敗');
}
```

### 3. 設置連接參數

```dart
_client.setConnectionTimeout(15000); // 15 秒超時
_client.setReconnectionDelay(3000);   // 3 秒重連延遲
_client.setMaxReconnectionAttempts(10); // 最大重連次數
```

## 常見問題

### 1. Android 模擬器連接問題

**問題**：Android 模擬器無法連接到 `localhost:8080`

**解決方案**：
- 使用主機 IP 地址而不是 `localhost`
- 在 Android 模擬器中，`localhost` 指向模擬器本身

### 2. iOS 模擬器連接問題

**問題**：iOS 模擬器連接不穩定

**解決方案**：
- iOS 模擬器可以使用 `localhost`
- 如果仍有問題，使用主機 IP 地址

### 3. 物理設備連接問題

**問題**：物理設備無法連接到開發機器

**解決方案**：
- 確保設備和開發機器在同一網絡
- 使用開發機器的實際 IP 地址
- 檢查防火牆設置

### 4. Docker 容器重啟問題

**問題**：容器重啟後 IP 地址改變

**解決方案**：
- 使用 Docker Compose 的服務名稱
- 配置固定的網絡設置
- 使用主機網絡模式

## 最佳實踐

### 1. 環境配置

```dart
class Environment {
  static const bool isProduction = false;
  static const String serverHost = isProduction 
    ? 'your-production-server.com' 
    : '192.168.0.103';
  static const int serverPort = isProduction ? 443 : 8080;
  static const bool useHttps = isProduction;
}
```

### 2. 連接重試機制

```dart
Future<bool> connectWithRetry({int maxRetries = 3}) async {
  for (int i = 0; i < maxRetries; i++) {
    try {
      final success = await _client.connect();
      if (success) return true;
    } catch (e) {
      print('連接嘗試 ${i + 1} 失敗: $e');
      if (i < maxRetries - 1) {
        await Future.delayed(Duration(seconds: 2));
      }
    }
  }
  return false;
}
```

### 3. 錯誤處理

```dart
_client.onError = (error) {
  if (error.contains('timeout')) {
    // 處理超時錯誤
    _showTimeoutDialog();
  } else if (error.contains('connection refused')) {
    // 處理連接拒絕錯誤
    _showConnectionErrorDialog();
  }
};
```

## 監控和調試

### 1. 啟用詳細日誌

```dart
_client.onLog = (log) {
  print('🔍 [DEBUG] $log');
};
```

### 2. 網絡狀態監控

```dart
Timer.periodic(Duration(seconds: 30), (timer) {
  _checkConnectionHealth();
});

Future<void> _checkConnectionHealth() async {
  final healthy = await TaxiAdHttpClient.testConnection();
  if (!healthy && _client.isConnected) {
    _client.disconnect();
    _reconnect();
  }
}
```

### 3. 性能監控

```dart
class ConnectionMetrics {
  int _connectionAttempts = 0;
  int _successfulConnections = 0;
  int _failedConnections = 0;
  
  void recordConnectionAttempt() {
    _connectionAttempts++;
  }
  
  void recordSuccessfulConnection() {
    _successfulConnections++;
  }
  
  void recordFailedConnection() {
    _failedConnections++;
  }
  
  double get successRate => 
    _connectionAttempts > 0 
      ? _successfulConnections / _connectionAttempts 
      : 0.0;
}
```

## 總結

Docker 網絡連接問題主要源於網絡隔離和 localhost 解析差異。通過使用主機 IP 地址、配置適當的網絡模式，以及實現健壯的錯誤處理機制，可以解決大部分連接問題。

建議的解決方案順序：
1. 使用主機 IP 地址（最簡單）
2. 配置 Docker host 網絡模式
3. 實現連接重試和錯誤處理機制
4. 添加監控和調試功能
