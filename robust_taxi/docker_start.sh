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

# 檢查 Docker Compose 是否安裝
if ! command -v docker-compose &> /dev/null; then
    echo " 錯誤：未安裝 Docker Compose"
    echo "請先安裝 Docker Compose"
    exit 1
fi

echo " Docker 環境檢查通過"
echo ""

# 進入項目目錄
cd "$(dirname "$0")"

echo " 步驟 1/5：停止舊容器（如果存在）..."
docker-compose -f docker/docker-compose.yml down 2>/dev/null || true
echo ""

echo "🔨 步驟 2/5：構建 Docker 鏡像..."
docker-compose -f docker/docker-compose.yml build
echo ""

echo " 步驟 3/5：啟動服務..."
docker-compose -f docker/docker-compose.yml up -d
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
INIT_URL="http://localhost:8080/init_db"
MAX_RETRIES=12
RETRY_INTERVAL=5

echo " 等待服務健康檢查通過（最多 $((MAX_RETRIES * RETRY_INTERVAL)) 秒）..."

for attempt in $(seq 1 $MAX_RETRIES); do
    if curl -s "$HEALTH_URL" > /dev/null 2>&1; then
        echo " 服務健康檢查通過（第 ${attempt} 次嘗試）"
        
        # 初始化數據庫
        echo ""
        echo "正在初始化數據庫..."
        INIT_RESULT=$(curl -s "$INIT_URL")
        
        if echo "$INIT_RESULT" | grep -q "\"status\":\"success\""; then
            echo " 數據庫初始化成功"
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
    echo "   docker-compose -f docker/docker-compose.yml logs --tail=200"
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo " 服務啟動成功！"
echo "════════════════════════════════════════════════════════"
echo ""
echo " 服務地址："
echo "   HTTP API:    http://localhost:8080"
echo "   WebSocket:   ws://localhost:8080"
echo "   MongoDB:     mongodb://localhost:27017"
echo ""
echo " 測試命令："
echo "   健康檢查:     curl http://localhost:8080/health"
echo "   查看連接:     curl http://localhost:8080/api/v1/admin/connections"
echo "   整合測試:     ./test_integration.sh"
echo ""
echo " 管理命令："
echo "   查看日誌:     docker-compose -f docker/docker-compose.yml logs -f"
echo "   查看狀態:     docker-compose -f docker/docker-compose.yml ps"
echo "   停止服務:     docker-compose -f docker/docker-compose.yml stop"
echo "   重啟服務:     docker-compose -f docker/docker-compose.yml restart"
echo "   完全停止:     docker-compose -f docker/docker-compose.yml down"
echo ""
echo " 查看文檔:     cat README.md"
echo " 快速開始:     cat QUICKSTART.md"
echo ""
echo "════════════════════════════════════════════════════════"

