#!/bin/bash

set -euo pipefail

REPO_DIR="$HOME/robust_taxi"
BRANCH="Gary"
ENV_FILE="docker/.env"
COMPOSE_ARGS=(--env-file "$ENV_FILE" -f docker/docker-compose.yml)

cd "$REPO_DIR"

echo "=== 更新前版本 ==="
git rev-parse --short HEAD

echo "=== 1/4 拉 GitHub 最新 code（$BRANCH）==="
git fetch origin -q
git checkout "$BRANCH" -q
git pull --ff-only -q origin "$BRANCH"
echo "  更新後版本：$(git rev-parse --short HEAD)"

echo "=== 2/4 檢查 $ENV_FILE ==="
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 找不到 $REPO_DIR/$ENV_FILE，停止部署。"
    exit 1
fi
docker compose "${COMPOSE_ARGS[@]}" config > /dev/null
echo "  env 與 Compose 設定有效"

echo "=== 3/4 重建 app + worker ==="
docker compose "${COMPOSE_ARGS[@]}" up -d --build smart_taxi_service mqtt_worker

echo "=== 4/4 驗證 ==="
sleep 6
HEALTH=$(curl -fsS http://localhost:8080/health)
echo "  health: $HEALTH"
echo "$HEALTH" | grep -q '"status":"healthy"'
docker compose "${COMPOSE_ARGS[@]}" ps --format 'table {{.Name}}\t{{.Status}}'
echo "✅ 部署完成。"
