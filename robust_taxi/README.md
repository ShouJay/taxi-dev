# 智能計程車廣告服務

完整的後端系統，結合基於地理位置的廣告決策和實時 WebSocket 推送功能。

**版本**: v2.0.0  
**技術**: Python + Flask + Flask-SocketIO + MongoDB + WebSocket  
**完成日期**: 2025-10-17

---

##  目錄

- [核心功能](#核心功能)
- [快速開始](#快速開始)
  - [Docker 部署（推薦）](#docker-部署推薦)
  - [本地運行](#本地運行)
- [API 文檔](#api-文檔)
- [WebSocket 事件](#websocket-事件)
- [測試](#測試)
- [技術架構](#技術架構)
- [數據模型](#數據模型)
- [Flutter App 開發](#flutter-app-開發)
- [故障排除](#故障排除)

---

##  核心功能

### 0. 雙螢幕與緊急廣播系統 (New)
- **多螢幕協作**: 支援 A/B 螢幕異步顯示（廣告/跑馬燈/即時數據）。
- **緊急插播**: 支援一鍵觸發警報，強制中斷播放並切換至地震速報。
- **QR Code 即時統計**: 使用者掃描後，數據即時推送至看板。
- **中控台**: 專屬網頁介面 `/control`，即時管理跑馬燈與警報狀態。

### 1.基於位置的智能廣告決策
- 設備定期發送 GPS 位置數據
- 服務器即時進行地理圍欄匹配
- 自動推送相關廣告到設備

### 2.WebSocket 實時雙向通信
- 持久化連接，低延遲推送（< 100ms）
- 設備註冊與連接管理
- 心跳檢測保持連接活性

### 3.管理員主動插播
- 支持緊急廣告即時推送
- 多設備批量推送
- 推送結果即時反饋

### 4.  連接狀態監控
- 實時查看活動設備
- 連接統計與分析
- 設備在線狀態追蹤

---

##  快速開始

### Docker 部署（推薦）

#### 一鍵啟動
```bash
./docker_start.sh
```

這個腳本會自動：
1.  檢查 Docker 環境
2.  停止舊容器
3.  構建鏡像
4.  啟動服務
5.  初始化數據庫

#### 一鍵停止
```bash
./docker_stop.sh
```

#### 手動操作
```bash
# 啟動服務
docker-compose -f docker/docker-compose.yml up -d

# 初始化數據庫
sleep 10
curl http://localhost:8080/init_db

# 查看日誌
docker-compose -f docker/docker-compose.yml logs -f

# 停止服務
docker-compose -f docker/docker-compose.yml down
```

---

### 本地運行

#### 1. 安裝依賴
```bash
# 創建虛擬環境
python3 -m venv venv
source venv/bin/activate  # macOS/Linux
# 或 venv\Scripts\activate  # Windows

# 安裝依賴
pip install -r requirements.txt
```

#### 2. 啟動 MongoDB
```bash
# macOS
brew services start mongodb-community

# 或使用 Docker
docker run -d -p 27017:27017 --name mongodb mongo:7.0
```

#### 3. 啟動服務
```bash
python run_app.py
```

服務將在 **http://localhost:8080** 啟動。

#### 4. 初始化數據庫
```bash
curl http://localhost:8080/init_db
```

---

##  測試

### 測試 1：健康檢查
```bash
curl http://localhost:8080/health
```

**預期響應**：
```json
{
  "status": "healthy",
  "database": "connected",
  "active_connections": 0,
  "total_connections": 0
}
```

### 測試 2：位置更新（模擬設備）
```bash
# 激活虛擬環境
source venv/bin/activate

# 運行測試客戶端（每 3 秒發送一次位置）
python tests/test_location_client.py taxi-AAB-1234-rooftop 3
```

**預期結果**：
-  設備成功連接並註冊
-  每 3 秒發送一次位置更新
-  當進入商圈範圍時自動收到廣告推送

### 測試 3：管理員推送
```bash
python tests/test_admin_push.py
```

### 測試 4：整合測試
```bash
./test_integration.sh
```

---

##  API 文檔

### HTTP 端點

#### 0. 雙螢幕控制 (V2)
- 中控台頁面: `GET /control`
- 狀態查詢: `GET /api/v2/control/status`
- 觸發警報: `POST /api/v2/control/trigger`
- 恢復正常: `POST /api/v2/control/reset`
- 設置跑馬燈: `POST /api/v2/config/marquee` (`{"text": "..."}`)
- QR 統計: `GET /api/v2/stats/qr`

#### 1. 健康檢查
```
GET /health
```

#### 2. 初始化數據庫
```
GET /init_db
```

#### 3. 設備心跳（HTTP 方式，向後兼容）
```
POST /api/v1/device/heartbeat
Content-Type: application/json

{
  "device_id": "taxi-AAB-1234-rooftop",
  "location": {
    "longitude": 121.5645,
    "latitude": 25.0330
  }
}
```

**響應**：
```json
{
  "command": "PLAY_VIDEO",
  "video_filename": "taipei101_tour_30s.mp4"
}
```

#### 4. 管理員推送
```
POST /api/v1/admin/override
Content-Type: application/json

{
  "target_device_ids": ["taxi-AAB-1234-rooftop"],
  "advertisement_id": "adv-002"
}
```

**響應**：
```json
{
  "status": "success",
  "advertisement": {
    "id": "adv-002",
    "name": "信義商圈購物促銷",
    "video_filename": "shopping_promo_20s.mp4"
  },
  "results": {
    "sent": ["taxi-AAB-1234-rooftop"],
    "offline": []
  },
  "summary": {
    "total_targets": 1,
    "sent_count": 1,
    "offline_count": 0
  }
}
```

#### 5. 查詢連接狀態
```
GET /api/v1/admin/connections
```

---

##  WebSocket 事件

### 連接 URL
```
ws://localhost:8080
```

### 客戶端發送的事件

#### 1. register - 註冊設備
```javascript
socket.emit('register', {
  device_id: 'taxi-AAB-1234-rooftop'
});
```

#### 2. location_update - 位置更新（核心功能）
```javascript
socket.emit('location_update', {
  device_id: 'taxi-AAB-1234-rooftop',
  longitude: 121.5645,
  latitude: 25.0330,
  timestamp: '2025-10-17T14:00:00'
});
```

**工作流程**：
1. 設備發送位置數據
2. 服務器執行地理圍欄匹配
3. 服務器即時推送匹配的廣告
4. 設備收到 `play_ad` 事件

#### 3. heartbeat - 心跳檢測
```javascript
socket.emit('heartbeat', {});
```

### 服務器發送的事件

#### 1. connection_established - 連接確認
```javascript
socket.on('connection_established', (data) => {
  console.log(data.message);
});
```

#### 2. registration_success - 註冊成功
```javascript
socket.on('registration_success', (data) => {
  console.log('設備已註冊:', data.device_id);
});
```

#### 3. play_ad - 播放廣告命令
```javascript
socket.on('play_ad', (data) => {
  console.log('收到廣告:', data.video_filename);
  console.log('觸發原因:', data.trigger);  // 'location_based' 或 'admin_override'
  
  // 播放廣告邏輯
  playVideo(data.video_filename);
});
```

**數據格式**：
```json
{
  "command": "PLAY_VIDEO",
  "video_filename": "taipei101_tour_30s.mp4",
  "trigger": "location_based",
  "device_id": "taxi-AAB-1234-rooftop",
  "location": {
    "longitude": 121.5645,
    "latitude": 25.0330
  },
  "timestamp": "2025-10-17T14:00:00"
}
```

---

##  技術架構

### 技術棧

| 類別 | 技術 | 版本 | 用途 |
|------|------|------|------|
| Web 框架 | Flask | 3.0.0 | HTTP API 服務 |
| WebSocket | Flask-SocketIO | 5.3.5 | 實時雙向通信 |
| 數據庫 | MongoDB | 7.0 | 數據存儲 |
| 地理空間 | MongoDB 2dsphere | - | 地理圍欄查詢 |
| Python | CPython | 3.10+ | 運行環境 |
| 容器化 | Docker | - | 部署 |

### 分層架構
```
┌─────────────────────────────────────┐
│         Application Layer           │  (app.py)
│  HTTP API + WebSocket Event Handler │
├─────────────────────────────────────┤
│          Service Layer              │  (services.py)
│    AdDecisionService + PushService  │
├─────────────────────────────────────┤
│         Database Layer              │  (database.py)
│    MongoDB Operations + Connection  │
├─────────────────────────────────────┤
│          Model Layer                │  (models.py)
│    Data Structures + Validation     │
└─────────────────────────────────────┘
```

### 項目結構
```
robust_taxi/
├── src/                            # 源代碼
│   ├── app.py                      # 主應用（HTTP + WebSocket）
│   ├── config.py                   # 配置管理
│   ├── database.py                 # 數據庫操作
│   ├── models.py                   # 數據模型
│   ├── services.py                 # 業務邏輯
│   └── sample_data.py              # 示例數據
├── tests/                          # 測試腳本
│   ├── test_location_client.py     # 位置更新測試
│   └── test_admin_push.py          # 管理員推送測試
├── docker/                         # Docker 配置
│   ├── Dockerfile
│   └── docker-compose.yml
├── run_app.py                      # 啟動腳本
├── docker_start.sh                 # Docker 一鍵啟動
├── docker_stop.sh                  # Docker 一鍵停止
├── test_integration.sh             # 整合測試
└── requirements.txt                # Python 依賴
```

---

##  數據模型

### 1. Devices Collection（設備集合）
```javascript
{
  "_id": "taxi-AAB-1234-rooftop",        // 設備唯一 ID
  "device_type": "rooftop_display",      // 設備類型
  "last_location": {                     // 最後位置
    "type": "Point",
    "coordinates": [121.5645, 25.0330]   // [經度, 緯度]
  },
  "groups": ["general", "tourists"],     // 目標群體
  "status": "active"                     // 狀態
}
```

### 2. Advertisements Collection（廣告集合）
```javascript
{
  "_id": "adv-001",                      // 廣告 ID
  "name": "台北 101 觀光廣告",            // 廣告名稱
  "type": "tourism",                     // 廣告類型
  "video_filename": "taipei101.mp4",     // 影片文件名
  "duration_seconds": 30,                // 播放時長
  "target_groups": ["tourists"],         // 目標群體
  "priority": 8,                         // 優先級 (0-10)
  "status": "active"                     // 狀態
}
```

### 3. Campaigns Collection（活動集合）
```javascript
{
  "_id": "camp-001",                     // 活動 ID
  "name": "信義區商圈推廣",               // 活動名稱
  "advertisement_id": "adv-001",         // 關聯廣告
  "geo_fence": {                         // 地理圍欄
    "type": "Polygon",
    "coordinates": [[[121.56, 25.03], [121.57, 25.03], ...]]]
  },
  "schedule": {                          // 投放時間
    "start_date": "2025-01-01",
    "end_date": "2025-12-31",
    "days_of_week": [1,2,3,4,5,6,7],     // 週一到週日
    "hours": [8,9,10,...,22]             // 8:00-22:00
  },
  "status": "active"                     // 狀態
}
```

### 內置測試數據

**設備**：
- `taxi-AAB-1234-rooftop` - 車頂顯示器（台北 101 附近）
- `taxi-BBB-5678-rooftop` - 車頂顯示器（西門町附近）
- `taxi-CCC-9012-interior` - 車內平板（市區）

**廣告**：
- `adv-001` - 台北 101 觀光廣告（信義區）
- `adv-002` - 西門町購物廣告（西門町）
- `adv-003` - 夜市美食廣告（全市）
- `adv-004` - 高端酒店廣告（商務區）

**地理圍欄**：
- 信義區商圈：台北 101 周邊
- 西門町商圈：西門町購物區
- 全台北市：涵蓋整個台北市區

---

##  Flutter App 開發

### 精簡版 Prompt（核心功能）

```markdown
# 智能計程車廣告測試 App（Flutter 精簡版）

## 核心功能
1. 發送位置數據到服務器
2. 接收廣告推送命令
3. 顯示影片播放列表

## 技術要求
- Flutter 3.16+
- 依賴：socket_io_client, provider, intl

## 界面設計（單頁面）
- 連接設置區：服務器地址、設備 ID、連接按鈕
- 位置發送區：選擇路線、調整頻率、開始/停止按鈕
- 播放列表區：顯示接收到的廣告

## 預設路線
- 台北 101: (121.5645, 25.0330)
- 西門町: (121.5070, 25.0420)
- 市區: (121.5200, 25.0400)

## WebSocket 事件
發送：register, location_update
接收：play_ad

## 默認配置
- 服務器：http://localhost:8080
- 設備 ID：taxi-AAB-1234-rooftop
- 更新頻率：3 秒

請提供完整可運行的 Flutter 項目代碼（4個文件）：
1. main.dart
2. websocket_service.dart
3. home_page.dart
4. constants.dart
```

---

##  故障排除

### 問題 1：MongoDB 連接失敗
```bash
# 檢查 MongoDB 是否運行
brew services list  # macOS
docker ps | grep mongo  # Docker

# 測試連接
mongosh mongodb://localhost:27017/
```

### 問題 2：端口被占用
```bash
# 查找占用端口的進程
lsof -ti:8080

# 終止進程
kill -9 $(lsof -ti:8080)

# 或修改端口（編輯 src/config.py）
export FLASK_PORT=8081
```

### 問題 3：WebSocket 連接失敗
- 檢查防火牆設置
- 確認 CORS 配置
- 使用瀏覽器開發者工具查看錯誤
- 檢查服務器日誌

### 問題 4：Docker 未安裝
```bash
# macOS 安裝 Docker
brew install --cask docker

# 啟動 Docker Desktop
open -a Docker

# 驗證安裝
docker --version
docker-compose --version
```

---

##  配置說明

### 環境變量

| 變量名 | 預設值 | 說明 |
|--------|--------|------|
| `MONGODB_URI` | `mongodb://localhost:27017/` | MongoDB 連接字符串 |
| `DATABASE_NAME` | `smart_taxi_ads` | 數據庫名稱 |
| `FLASK_HOST` | `0.0.0.0` | Flask 監聽地址 |
| `FLASK_PORT` | `8080` | Flask 監聽端口 |
| `FLASK_DEBUG` | `True` | 調試模式 |

### 修改配置

編輯 `src/config.py`：
```python
MONGODB_URI = os.getenv('MONGODB_URI', 'mongodb://localhost:27017/')
DATABASE_NAME = os.getenv('DATABASE_NAME', 'smart_taxi_ads')
FLASK_PORT = int(os.getenv('FLASK_PORT', 8080))
```

---

##  使用場景

### 場景 1：開發測試
```bash
# 使用本地 Python 環境
python run_app.py
python tests/test_location_client.py
```

### 場景 2：功能演示
```bash
# 使用 Docker 一鍵啟動
./docker_start.sh
```

### 場景 3：生產部署
```bash
# 使用 Docker Compose
docker-compose -f docker/docker-compose.yml up -d
```

---

##  常用命令速查

```bash
# 啟動
./docker_start.sh                                              # Docker 一鍵啟動
python run_app.py                                              # 本地啟動

# 測試
curl http://localhost:8080/health                              # 健康檢查
curl http://localhost:8080/init_db                             # 初始化數據庫
./test_integration.sh                                          # 整合測試
python tests/test_location_client.py taxi-AAB-1234-rooftop 3  # 位置測試
python tests/test_admin_push.py                                # 推送測試

# Docker 管理
docker-compose -f docker/docker-compose.yml ps                 # 查看狀態
docker-compose -f docker/docker-compose.yml logs -f            # 查看日誌
docker-compose -f docker/docker-compose.yml restart            # 重啟服務
docker-compose -f docker/docker-compose.yml down               # 停止服務

# 停止
./docker_stop.sh                                               # Docker 一鍵停止
```

---

##  項目特色

 **整合版架構** - 單一服務，部署簡單  
 **位置驅動推送** - 設備上報位置，自動推送廣告  
 **WebSocket 實時通信** - 低延遲，雙向通信  
 **管理員主動插播** - 支持緊急廣告即時推送  
 **Docker 一鍵部署** - 完整的容器化方案  
 **完整測試覆蓋** - 位置更新、管理推送、整合測試  


