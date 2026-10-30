#!/usr/bin/env bash
# 开启服务端分支保护（GitHub 侧强制）。
#
# 当前仓库是 GitHub Free + private，这个脚本会返回 403：
#   "Upgrade to GitHub Pro or make this repository public to enable this feature."
# 免费方案（见 CONTRIBUTING.md §1.1）只能靠 .githooks/pre-push 与 main-guard 工作流。
#
# 满足以下任一条件后再运行本脚本，即可获得真正的服务端强制：
#   - 仓库转为 public（GitHub Free 支持）
#   - 组织升级到 Team / Enterprise（私有仓库支持）
#
# 用法：
#   bash scripts/enable-branch-protection.sh [owner/repo]

set -euo pipefail

repo="${1:-bycicle-locating/bycicle-locating}"

echo "目标仓库: $repo"
echo "将要设置："
echo "  - 必须走 PR（审批数 0，适合单人维护；有第二人后改成 1）"
echo "  - 必需检查：build / analyze-and-test / host-tests（必须先跑过一次）"
echo "  - 严格模式：分支落后 main 时必须先 rebase"
echo "  - 线性历史、禁止强推、禁止删除、必须解决对话"
echo

payload=$(mktemp)
trap 'rm -f "$payload"' EXIT

cat >"$payload" <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["build", "analyze-and-test", "host-tests"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON

if gh api -X PUT "repos/$repo/branches/main/protection" --input "$payload" >/dev/null 2>&1; then
    echo "✅ 已开启分支保护。"
    gh api "repos/$repo/branches/main/protection" --jq '{
      checks: .required_status_checks.contexts,
      strict: .required_status_checks.strict,
      linear: .required_linear_history.enabled,
      force_push: .allow_force_pushes.enabled,
      deletions: .allow_deletions.enabled
    }'
else
    echo "❌ 开启失败。常见原因与处理："
    echo "   1) 私有仓库 + GitHub Free → 转 public，或把组织升级到 Team。"
    echo "   2) 必需的检查名对不上 → 先跑一次 CI，用"
    echo "      gh api repos/$repo/commits/main/check-runs --jq '.check_runs[].name'"
    echo "      核对名称，再改本脚本顶部的 contexts。"
    echo "   3) 没有 admin 权限 → 用有权限的账号执行。"
    exit 1
fi
