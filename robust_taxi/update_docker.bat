@echo off
REM =============================================================================
REM Docker 程式碼更新執行檔 (Windows 版本)
REM 用於將本地程式碼更新到 Docker 容器中
REM =============================================================================

setlocal enabledelayedexpansion

REM 設置顏色 (Windows 10+)
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "RED=%ESC%[31m"
set "GREEN=%ESC%[32m"
set "YELLOW=%ESC%[33m"
set "BLUE=%ESC%[34m"
set "NC=%ESC%[0m"

REM 日誌函數
:log_info
echo %BLUE%[INFO]%NC% %~1
goto :eof

:log_success
echo %GREEN%[SUCCESS]%NC% %~1
goto :eof

:log_warning
echo %YELLOW%[WARNING]%NC% %~1
goto :eof

:log_error
echo %RED%[ERROR]%NC% %~1
goto :eof

REM 檢查 Docker 是否運行
:check_docker
call :log_info "檢查 Docker 狀態..."
docker info >nul 2>&1
if errorlevel 1 (
    call :log_error "Docker 未運行，請先啟動 Docker Desktop"
    exit /b 1
)
call :log_success "Docker 運行正常"
goto :eof

REM 檢查 Docker Compose 是否可用
:check_docker_compose
call :log_info "檢查 Docker Compose..."
docker-compose --version >nul 2>&1
if errorlevel 1 (
    call :log_error "Docker Compose 未安裝"
    exit /b 1
)
call :log_success "Docker Compose 可用"
goto :eof

REM 停止現有容器
:stop_containers
call :log_info "停止現有容器..."
cd docker
docker-compose down
if errorlevel 1 (
    call :log_warning "停止容器時出現警告"
)
call :log_success "容器已停止"
cd ..
goto :eof

REM 清理舊的鏡像
:cleanup_images
if "%1"=="--clean" (
    call :log_info "清理舊的 Docker 鏡像..."
    docker image prune -f
    call :log_success "舊鏡像已清理"
)
goto :eof

REM 重新構建並啟動容器
:rebuild_and_start
call :log_info "重新構建 Docker 鏡像..."
cd docker
docker-compose build --no-cache
if errorlevel 1 (
    call :log_error "Docker 鏡像構建失敗"
    exit /b 1
)
call :log_success "Docker 鏡像構建完成"

call :log_info "啟動容器..."
docker-compose up -d
if errorlevel 1 (
    call :log_error "容器啟動失敗"
    exit /b 1
)
call :log_success "容器已啟動"
cd ..
goto :eof

REM 檢查容器狀態
:check_container_status
call :log_info "檢查容器狀態..."
timeout /t 5 /nobreak >nul

REM 檢查 MongoDB 容器
docker ps | findstr "smart_taxi_mongodb" >nul
if errorlevel 1 (
    call :log_error "MongoDB 容器未運行"
    exit /b 1
)
call :log_success "MongoDB 容器運行正常"

REM 檢查服務容器
docker ps | findstr "smart_taxi_service" >nul
if errorlevel 1 (
    call :log_error "智能計程車服務容器未運行"
    exit /b 1
)
call :log_success "智能計程車服務容器運行正常"
goto :eof

REM 檢查服務健康狀態
:check_service_health
call :log_info "檢查服務健康狀態..."

REM 等待服務啟動
for /l %%i in (1,1,30) do (
    curl -f http://localhost:8080/health >nul 2>&1
    if not errorlevel 1 (
        call :log_success "服務健康檢查通過"
        goto :eof
    )
    call :log_info "等待服務啟動... (%%i/30)"
    timeout /t 2 /nobreak >nul
)

call :log_warning "服務健康檢查超時，但容器可能仍在啟動中"
goto :eof

REM 顯示容器日誌
:show_logs
call :log_info "顯示容器日誌..."
echo ==========================================
docker logs smart_taxi_service --tail=20
echo ==========================================
goto :eof

REM 顯示使用說明
:show_usage
echo 用法: %~nx0 [選項]
echo.
echo 選項:
echo   --clean     清理舊的 Docker 鏡像
echo   --logs      顯示容器日誌
echo   --help      顯示此說明
echo.
echo 範例:
echo   %~nx0              # 基本更新
echo   %~nx0 --clean      # 清理後更新
echo   %~nx0 --logs       # 更新後顯示日誌
goto :eof

REM 主函數
:main
echo ==========================================
echo 🐳 Docker 程式碼更新工具 (Windows)
echo ==========================================

REM 解析命令行參數
set "CLEAN_IMAGES=false"
set "SHOW_LOGS=false"

:parse_args
if "%~1"=="" goto :start_update
if "%~1"=="--clean" (
    set "CLEAN_IMAGES=true"
    shift
    goto :parse_args
)
if "%~1"=="--logs" (
    set "SHOW_LOGS=true"
    shift
    goto :parse_args
)
if "%~1"=="--help" (
    call :show_usage
    exit /b 0
)
call :log_error "未知參數: %~1"
call :show_usage
exit /b 1

:start_update
REM 執行更新流程
call :check_docker
if errorlevel 1 exit /b 1

call :check_docker_compose
if errorlevel 1 exit /b 1

call :stop_containers

if "%CLEAN_IMAGES%"=="true" (
    call :cleanup_images --clean
)

call :rebuild_and_start
if errorlevel 1 exit /b 1

call :check_container_status
if errorlevel 1 exit /b 1

call :check_service_health

if "%SHOW_LOGS%"=="true" (
    call :show_logs
)

echo.
call :log_success "🎉 Docker 更新完成！"
echo.
echo 服務資訊:
echo   - Web 管理介面: http://localhost:8080/admin_dashboard_v2.html
echo   - WebSocket 端點: ws://localhost:8080
echo   - MongoDB: localhost:27017
echo.
echo 常用命令:
echo   - 查看日誌: docker logs smart_taxi_service -f
echo   - 停止服務: cd docker ^&^& docker-compose down
echo   - 重啟服務: cd docker ^&^& docker-compose restart

goto :eof

REM 執行主函數
call :main %*
