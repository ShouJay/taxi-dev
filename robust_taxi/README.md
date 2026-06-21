# 智能計程車廣告服務（MQTT-only）

本專案為計程車車載廣告後端，已全面改為 MQTT 架構，不再使用 WebSocket。

## 核心重點

- 通訊協議：MQTT（EMQX）
- 後端：Flask（管理 API / 下載 API / 控制 API）
- 決策：`mqtt_worker` 訂閱位置並計算 `desired playlist`
- 資料庫：MongoDB（含地理索引 + Device Shadow）
- 影片完整性：上傳完成時計算 MD5，寫入 `advertisements.md5_hash`

## 服務組成

`docker/docker-compose.yml` 啟動以下服務：

- `mongodb`：資料庫
- `emqx`：MQTT broker（1883）
- `smart_taxi_service`：Flask API（8080）
- `mqtt_worker`：MQTT 訂閱與 LBS 決策 worker

## 快速開始

### 一鍵啟動（推薦）

```bash
./docker_start.sh
```

腳本會：

1. 檢查 Docker 環境
2. 停掉舊容器
3. 重新 build
4. 啟動 MongoDB + EMQX + API + MQTT Worker
5. 執行 `/init_db`

### 一鍵暫停 / 停止

```bash
./docker_stop.sh
```

- 選項 `1`：暫停所有服務（含 EMQX 與 MQTT Worker）
- 選項 `2`：刪容器保留 volume
- 選項 `3`：完整清除（含 volume）

## MQTT Topic 規範

- `taxi/{device_id}/location`：設備上報位置（QoS 0）
- `taxi/{device_id}/playlist/desired`：後端下發播放清單（QoS 1, retain）
- `taxi/{device_id}/playlist/reported`：設備回報狀態（QoS 1）
- `taxi/{device_id}/status`：設備上下線狀態（QoS 1，支援 LWT）
- `taxi/all/emergency`：緊急廣播（QoS 1）

## 主要 HTTP API

- `GET /health`：健康檢查（DB + MQTT 連線摘要）
- `GET /init_db`：初始化資料
- `POST /api/v1/device/heartbeat`：舊版 HTTP 相容心跳
- `GET /api/v1/device/videos/<advertisement_id>/download`：下載資訊
- `GET /api/v1/device/videos/<advertisement_id>/chunk`：下載分片
- `POST /api/v1/admin/videos/rehash`：補算缺失 MD5
- `POST /api/v2/control/trigger`：觸發緊急狀態
- `POST /api/v2/control/reset`：恢復正常

## MQTT 快速驗證

先訂閱 `desired`：

```bash
mosquitto_sub -h localhost -t "taxi/test-device/playlist/desired" -v
```

再發送位置：

```bash
mosquitto_pub -h localhost -t "taxi/test-device/location" -m '{"lat":25.033,"lng":121.543}'
```

如果該設備與活動條件符合，會收到 `desired` payload。

## 常用命令

```bash
# 啟動 / 停止
./docker_start.sh
./docker_stop.sh

# 狀態 / 日誌
docker compose -f docker/docker-compose.yml ps
docker compose -f docker/docker-compose.yml logs -f

# 健康檢查
curl http://localhost:8080/health
```

## 專案結構（核心）

```text
robust_taxi/
├── src/
│   ├── app.py
│   ├── admin_api.py
│   ├── dual_screen_api.py
│   ├── emergency_manager.py
│   ├── mqtt_client.py
│   ├── mqtt_worker.py
│   ├── services.py
│   ├── models.py
│   └── database.py
├── docker/
│   └── docker-compose.yml
├── run_app.py
├── run_mqtt_worker.py
├── docker_start.sh
└── docker_stop.sh
```
