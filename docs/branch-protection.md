# 分支保护（main）

`main` 的保护规则已经在 GitHub 上生效，**本页是这套规则的唯一说明**。

> 早先用于首次配置的 `scripts/enable-branch-protection.sh` 已完成使命并删除：
> 它把规则写死在脚本里，容易和线上实际配置各说各话。需要重建时按本页的参数在网页里操作，
> 或直接用文末的 API 载荷。

## 1. 当前生效的规则

| 规则 | 值 | 理由 |
|---|---|---|
| 必须走 PR | 是，审批数 **0** | 单人维护：GitHub 不允许自我批准，设成 1 会把作者锁在门外；有第二人后改成 1 |
| 必需状态检查 | `build`、`analyze-and-test`、`host-tests` | 与三个 workflow 的 **job 名**一致，改 job 名必须同步改这里 |
| 严格模式（strict） | 是 | 分支落后 `main` 时必须先 rebase，防止"本地绿、合并后红" |
| 线性历史 | 是 | 配合 squash-only 的合并设置，`main` 保持一条直线 |
| 禁止强推 / 禁止删除 | 是 / 是 | 历史不可改写，分支不可误删 |
| 必须解决对话 | 是 | 评审意见不能"已读不回"直接合 |
| `enforce_admins` | **true** | 管理员也必须走 PR |

配套的仓库设置：只允许 squash 合并、合并后自动删除头部分支。

### 为什么 `enforce_admins` 必须是 true

开启保护后实测过 `false` 的行为：用管理员身份绕过本地 hook 直推 `main`，服务端**放行**了，
只在输出里留了一句：

```
remote: Bypassed rule violations for refs/heads/main:
remote: - Changes must be made through a pull request.
remote: - 3 of 3 required status checks are expected.
```

也就是说 `false` 时规则只是"提醒"。改成 `true` 后同样的操作变成硬拒绝：
`GH006: Protected branch update failed for refs/heads/main`。
**单人维护不等于要留后门**——真需要时临时停用规则即可，见 §3。

## 2. 依赖这套规则的两个前提

1. **检查名必须真实存在**。`build` / `analyze-and-test` / `host-tests` 是三个 workflow 的 job 名；
   重命名 job 会让对应检查永远处于 `Expected`，所有 PR 都合不进来。
2. **三个 workflow 不加 `paths` 过滤**。只改文档的 PR 若跳过某个 workflow，那个必需检查同样永远
   凑不齐。这也是它们现在每次都跑的原因。

## 3. 应急：临时停用与恢复

直推被卡住且确实必须处理时（例如误提交了不该进历史的文件）：

1. Settings → Branches → `main` 规则右侧 `⋯` → **Delete rule**；
2. 用管理员身份完成需要绕过保护的操作（`SKIP_MAIN_GUARD=1` 绕过本地 hook）；
3. **立刻**按 §1 的表格重建规则。

停用期间保护不存在，`main-guard` 只能事后标红。不要把停用当成常态。

## 4. 用 API 重建（可选）

参数与 §1 一致，`contexts` 必须与 job 名逐字一致：

```bash
gh api -X PUT repos/bycicle-locating/bycicle-locating/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["build", "analyze-and-test", "host-tests"]
  },
  "enforce_admins": true,
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
```

核对：

```bash
gh api repos/bycicle-locating/bycicle-locating/branches/main/protection \
  --jq '{admins: .enforce_admins.enabled, pr: (.required_pull_request_reviews != null),
         checks: .required_status_checks.contexts, strict: .required_status_checks.strict}'
```

## 5. 背景：为什么之前用不了

仓库最初是 **private**，GitHub Free 套餐不支持私有仓库的分支保护与 Rulesets
（API 返回 `403 Upgrade to GitHub Pro or make this repository public`）。
把仓库转为 public 之后才可用；组织升级到 Team 也能在私有仓库上解锁同样的能力。
