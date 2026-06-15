#!/bin/bash

# =============================================================================
# Docker 程式碼更新執行檔
# 用於將本地程式碼更新到 Docker 容器中
# =============================================================================

set -e  # 遇到錯誤時停止執行

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日誌函數
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 檢查 Docker 是否運行
check_docker() {
    log_info "檢查 Docker 狀態..."
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker 未運行，請先啟動 Docker"
        exit 1
    fi
    log_success "Docker 運行正常"
}

# 檢查 Docker Compose 是否可用
check_docker_compose() {
    log_info "檢查 Docker Compose..."
    if ! command -v docker-compose > /dev/null 2>&1; then
        log_error "Docker Compose 未安裝"
        exit 1
    fi
    log_success "Docker Compose 可用"
}

# 停止現有容器
stop_containers() {
    log_info "停止現有容器..."
    cd docker
    docker-compose down
    log_success "容器已停止"
    cd ..
}

# 清理舊的鏡像（可選）
cleanup_images() {
    if [ "$1" = "--clean" ]; then
        log_info "清理舊的 Docker 鏡像..."
        docker image prune -f
        log_success "舊鏡像已清理"
    fi
}

# 重新構建並啟動容器
rebuild_and_start() {
    log_info "重新構建 Docker 鏡像..."
    cd docker
    docker-compose build --no-cache
    log_success "Docker 鏡像構建完成"
    
    log_info "啟動容器..."
    docker-compose up -d
    log_success "容器已啟動"
    cd ..
}

# 檢查容器狀態
check_container_status() {
    log_info "檢查容器狀態..."
    sleep 5  # 等待容器完全啟動
    
    # 檢查 MongoDB 容器
    if docker ps | grep -q "smart_taxi_mongodb"; then
        log_success "MongoDB 容器運行正常"
    else
        log_error "MongoDB 容器未運行"
        return 1
    fi
    
    # 檢查服務容器
    if docker ps | grep -q "smart_taxi_service"; then
        log_success "智能計程車服務容器運行正常"
    else
        log_error "智能計程車服務容器未運行"
        return 1
    fi
}

# 檢查服務健康狀態
check_service_health() {
    log_info "檢查服務健康狀態..."
    
    # 等待服務啟動
    for i in {1..30}; do
        if curl -f http://localhost:8080/health > /dev/null 2>&1; then
            log_success "服務健康檢查通過"
            return 0
        fi
        log_info "等待服務啟動... ($i/30)"
        sleep 2
    done
    
    log_warning "服務健康檢查超時，但容器可能仍在啟動中"
    return 0
}

# 顯示容器日誌
show_logs() {
    log_info "顯示容器日誌..."
    echo "=========================================="
    docker logs smart_taxi_service --tail=20
    echo "=========================================="
}

# 顯示使用說明
show_usage() {
    echo "用法: $0 [選項]"
    echo ""
    echo "選項:"
    echo "  --clean     清理舊的 Docker 鏡像"
    echo "  --logs      顯示容器日誌"
    echo "  --help      顯示此說明"
    echo ""
    echo "範例:"
    echo "  $0              # 基本更新"
    echo "  $0 --clean      # 清理後更新"
    echo "  $0 --logs       # 更新後顯示日誌"
}

# 主函數
main() {
    echo "=========================================="
    echo "🐳 Docker 程式碼更新工具"
    echo "=========================================="
    
    # 解析命令行參數
    CLEAN_IMAGES=false
    SHOW_LOGS=false
    
    for arg in "$@"; do
        case $arg in
            --clean)
                CLEAN_IMAGES=true
                ;;
            --logs)
                SHOW_LOGS=true
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知參數: $arg"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # 執行更新流程
    check_docker
    check_docker_compose
    stop_containers
    
    if [ "$CLEAN_IMAGES" = true ]; then
        cleanup_images --clean
    fi
    
    rebuild_and_start
    
    if check_container_status; then
        check_service_health
        
        if [ "$SHOW_LOGS" = true ]; then
            show_logs
        fi
        
        echo ""
        log_success "🎉 Docker 更新完成！"
        echo ""
        echo "服務資訊:"
        echo "  - Web 管理介面: http://localhost:8080/admin_dashboard_v2.html"
        echo "  - WebSocket 端點: ws://localhost:8080"
        echo "  - MongoDB: localhost:27017"
        echo ""
        echo "常用命令:"
        echo "  - 查看日誌: docker logs smart_taxi_service -f"
        echo "  - 停止服務: cd docker && docker-compose down"
        echo "  - 重啟服務: cd docker && docker-compose restart"
    else
        log_error "容器啟動失敗"
        show_logs
        exit 1
    fi
}

# 執行主函數
main "$@"
