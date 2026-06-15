#!/bin/bash

# 智能計程車廣告服務 - Docker 停止腳本

cd "$(dirname "$0")"

echo "════════════════════════════════════════════════════════"
echo "🛑 停止智能計程車廣告服務"
echo "════════════════════════════════════════════════════════"
echo ""

echo "請選擇停止方式："
echo "  1) 停止服務（保留容器和數據）"
echo "  2) 停止並刪除容器（保留數據卷）"
echo "  3) 完全清理（刪除容器和數據）"
echo ""
read -p "請輸入選項 (1/2/3): " choice

case $choice in
    1)
        echo ""
        echo "🛑 正在停止服務..."
        docker-compose -f docker/docker-compose.yml stop
        echo "✅ 服務已停止"
        echo ""
        echo "💡 重新啟動: docker-compose -f docker/docker-compose.yml start"
        ;;
    2)
        echo ""
        echo "🗑️ 正在停止並刪除容器..."
        docker-compose -f docker/docker-compose.yml down
        echo "✅ 容器已刪除（數據已保留）"
        echo ""
        echo "💡 重新啟動: ./docker_start.sh"
        ;;
    3)
        echo ""
        echo "⚠️ 警告：這將刪除所有數據！"
        read -p "確定要繼續嗎？(yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            echo "🗑️ 正在刪除所有內容..."
            docker-compose -f docker/docker-compose.yml down -v
            echo "✅ 已完全清理"
            echo ""
            echo "💡 重新啟動: ./docker_start.sh"
        else
            echo "❌ 已取消"
        fi
        ;;
    *)
        echo "❌ 無效選項"
        exit 1
        ;;
esac

echo ""
echo "════════════════════════════════════════════════════════"

