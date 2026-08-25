#!/bin/bash

# 智能計程車廣告服務 - Docker 一鍵啟動腳本

set -e  # 遇到錯誤立即退出

echo "════════════════════════════════════════════════════════"
echo "🚕 智能計程車廣告服務 - Docker 啟動"
echo "════════════════════════════════════════════════════════"
echo ""

# 檢查 Docker 是否安裝
if ! command -v docker &> /dev/null; then
    echo " 錯誤：未安裝 Docker"
    echo "請先安裝 Docker: https://www.docker.com/get-started"
    exit 1
fi

# 檢查 Docker Compose 是否安裝（v2）
if ! docker compose version &> /dev/null; then
    echo " 錯誤：未安裝 Docker Compose v2（docker compose）"
    exit 1
fi

echo " Docker 環境檢查通過"
echo ""

# 進入項目目錄
cd "$(dirname "$0")"

ENV_FILE=docker/.env
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 找不到 $ENV_FILE"
    echo "請先執行：cp docker/.env.example docker/.env，再修改成目標環境的設定。"
    exit 1
fi

COMPOSE_ARGS=(--env-file "$ENV_FILE" -f docker/docker-compose.yml)
if [ -n "${COMPOSE_OVERRIDE_FILE:-}" ]; then
    COMPOSE_ARGS+=(-f "$COMPOSE_OVERRIDE_FILE")
fi

# 首次導入 persistent volume 前，阻止舊容器內的影片被 down 刪除。
if docker container inspect smart_taxi_service > /dev/null 2>&1; then
    UPLOAD_MOUNTED=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/uploads"}}yes{{end}}{{end}}' smart_taxi_service)
    if [ "$UPLOAD_MOUNTED" != "yes" ] && \
       docker exec smart_taxi_service sh -c 'test -d /app/uploads && find /app/uploads -type f -print -quit | grep -q .'; then
        echo "❌ 偵測到舊容器內有未持久化的影片，為避免資料遺失已停止部署。"
        echo "請先參考 README 的「首次 volume 遷移」備份與還原影片。"
        exit 1
    fi
fi

echo " 步驟 1/5：停止舊容器（如果存在）..."
docker compose "${COMPOSE_ARGS[@]}" down 2>/dev/null || true
echo ""

echo "🔨 步驟 2/5：構建 Docker 鏡像..."
docker compose "${COMPOSE_ARGS[@]}" build
echo ""

echo " 步驟 3/5：啟動服務（MongoDB + EMQX + API + MQTT Worker）..."
docker compose "${COMPOSE_ARGS[@]}" up -d
echo ""

echo " 步驟 4/5：等待服務啟動（10 秒）..."
for i in {10..1}; do
    echo -n "$i... "
    sleep 1
done
echo ""
echo ""

echo " 步驟 5/5：初始化數據庫..."
sleep 2  # 額外等待確保服務完全就緒

HEALTH_URL="http://localhost:8080/health"
MIGRATE_URL="http://localhost:8080/migrate_db"
MAX_RETRIES=12
RETRY_INTERVAL=5

echo " 等待服務健康檢查通過（最多 $((MAX_RETRIES * RETRY_INTERVAL)) 秒）..."

for attempt in $(seq 1 $MAX_RETRIES); do
    if curl -s "$HEALTH_URL" > /dev/null 2>&1; then
        echo " 服務健康檢查通過（第 ${attempt} 次嘗試）"
        
        # 執行非破壞性 migration
        echo ""
        echo "正在執行資料庫 migration..."
        INIT_RESULT=$(curl -s -X POST "$MIGRATE_URL")
        
        if echo "$INIT_RESULT" | grep -q "\"status\":\"success\""; then
            echo " 數據庫 migration 成功"
        else
            echo " ⚠️ 數據庫初始化可能失敗，API 回應如下："
            echo " $INIT_RESULT"
        fi
        HEALTH_OK=true
        break
    else
        echo " 服務尚未就緒，${RETRY_INTERVAL} 秒後重試... (第 ${attempt}/${MAX_RETRIES} 次)"
        sleep $RETRY_INTERVAL
    fi
done

if [ -z "${HEALTH_OK}" ]; then
    echo ""
    echo " ❌ 服務在預期時間內未通過健康檢查。"
    echo " 請查看日誌以深入分析："
    echo "   docker compose ${COMPOSE_ARGS[*]} logs --tail=200"
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo " 服務啟動成功！"
echo "════════════════════════════════════════════════════════"
echo ""
echo " 服務地址："
echo "   HTTP API:    http://localhost:8080"
echo "   MQTT Broker: mqtt://localhost:1883"
echo "   EMQX Dashboard: http://localhost:18083"
echo "   MongoDB:     mongodb://localhost:27017"
echo ""
echo " 測試命令："
echo "   健康檢查:     curl http://localhost:8080/health"
echo "   查看連接:     curl http://localhost:8080/api/v1/admin/connections"
echo "   整合測試:     ./test_integration.sh"
echo ""
echo " 管理命令："
echo "   查看日誌:     docker compose ${COMPOSE_ARGS[*]} logs -f"
echo "   查看狀態:     docker compose ${COMPOSE_ARGS[*]} ps"
echo "   暫停服務:     docker compose ${COMPOSE_ARGS[*]} stop"
echo "   重啟服務:     docker compose ${COMPOSE_ARGS[*]} restart"
echo "   完全停止:     docker compose ${COMPOSE_ARGS[*]} down"
echo ""
echo " 查看文檔:     cat README.md"
echo " 快速開始:     cat QUICKSTART.md"
echo ""
echo "════════════════════════════════════════════════════════"
