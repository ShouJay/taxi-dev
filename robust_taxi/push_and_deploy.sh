#!/bin/bash
# ============================================================
# 一鍵：commit + push 本機改動到 GitHub，再遠端觸發 VM 部署
#   用法： bash push_and_deploy.sh "這次改了什麼（commit 訊息）"
#
#   誰改完 code 就在自己電腦跑這一支，全自動完成：
#     1) commit + push 到 GitHub（Gary 分支）
#     2) SSH 連進 VM
#     3) 在 VM 上跑 vm_deploy.sh（拉最新 → 重建 app+worker → 驗證）
#
#   ※ 第一次用：先把下面「設定區」改成你自己的
#     （VM_IP 向管理者索取；不要把它 commit 進公開 repo）
# ============================================================
set -euo pipefail

# ============ 設定區（每個人改成自己的，勿 commit 回 repo）============
REPO_DIR="$HOME/path/to/robust_taxi"   # 你的 robust_taxi 本機 clone 路徑
SSH_KEY="$HOME/.ssh/taxi_vm"           # 你連 VM 用的「私鑰」（換成你自己的）
VM_IP="請填入VM公網IP"                  # 向管理者索取，例如 20.1.2.3
BRANCH="Gary"
ADMIN_USER="azureuser"
# ====================================================================

# 防呆：確認設定區已填好
case "$VM_IP" in ""|*請填入*|*"<"*) echo "❌ 請先改腳本最上面的設定區（REPO_DIR / SSH_KEY / VM_IP）"; exit 1;; esac
[ -d "$REPO_DIR/.git" ] || { echo "❌ REPO_DIR 不是有效的 git 專案：$REPO_DIR"; exit 1; }

MSG="${1:-update $(date +%Y-%m-%d_%H:%M)}"

cd "$REPO_DIR"

echo "=== 1/3 commit + push (${BRANCH}) ==="
git add -A
if git diff --cached --quiet; then
  echo "  沒有新改動，略過 commit"
else
  git commit -m "$MSG"
  echo "  已 commit：$MSG"
fi
git push origin "$BRANCH"

echo "=== 2/3 + 3/3 連進 VM 觸發部署 ==="
ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=20 "$ADMIN_USER@$VM_IP" './vm_deploy.sh'

echo ""
echo "✅ 全部完成：改動已上 GitHub 並部署到 VM。"
echo "   健康檢查： http://$VM_IP:8080/health"
