#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"

VIDEO_DATA_PATH="${VIDEO_DATA_PATH:-/data/robust-taxi/uploads}"

case "$VIDEO_DATA_PATH" in
    /*) ;;
    *)
        echo "❌ VIDEO_DATA_PATH 必須是絕對路徑：$VIDEO_DATA_PATH"
        exit 1
        ;;
esac

if [ ! -d "$VIDEO_DATA_PATH" ]; then
    echo "❌ 影片目錄不存在：$VIDEO_DATA_PATH"
    echo "請先掛載 Azure Managed Data Disk 並建立目錄；腳本不會自動建立，以免誤寫到 OS Disk。"
    exit 1
fi

if [ ! -w "$VIDEO_DATA_PATH" ]; then
    echo "❌ 影片目錄無法寫入：$VIDEO_DATA_PATH"
    exit 1
fi

if ! command -v findmnt > /dev/null 2>&1; then
    echo "❌ 找不到 findmnt，無法確認影片目錄是否位於資料磁碟。"
    exit 1
fi

MOUNT_TARGET=$(findmnt --noheadings --output TARGET --target "$VIDEO_DATA_PATH" | head -n 1)
if [ -z "$MOUNT_TARGET" ] || [ "$MOUNT_TARGET" = "/" ]; then
    echo "❌ $VIDEO_DATA_PATH 不在獨立掛載的資料磁碟上。"
    echo "請先檢查 Azure Managed Data Disk 與 /etc/fstab，避免影片寫入 OS Disk。"
    exit 1
fi

echo "✅ 影片資料磁碟檢查通過：$VIDEO_DATA_PATH（mount: $MOUNT_TARGET）"

export VIDEO_DATA_PATH
export COMPOSE_OVERRIDE_FILE=docker/docker-compose.azure-vm.yml

exec ./docker_start.sh
