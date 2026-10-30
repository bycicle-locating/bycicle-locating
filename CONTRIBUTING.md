# 协作规范

本仓库是三层单体仓库（monorepo）：`app/` Flutter 端、`firmware/` ESP-IDF 固件、`backend/` Go 服务。
三者通过文档化契约解耦，**不是**通过共享代码解耦。

## 1. 分支与提交

- 主干为 `main`，保持随时可构建。功能分支从 `main` 切出，命名 `feat/<范围>-<简述>`、`fix/<范围>-<简述>`、`docs/<简述>`。范围取 `app` / `fw` / `backend` / `docs`。
- 提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/)：`<type>(<scope>): <中文简述>`，例如 `feat(fw): 增加 GPS 定位上报`、`fix(backend): 修正幂等去重边界`。
- 一次提交只做一件事。**禁止**把格式化、重命名和逻辑改动混在同一提交里。
- 不提交 `sdkconfig`、`.env`、密钥、证书私钥、`build/` 产物。见 `.gitignore`。

### 1.1 合并流程（main 受保护）

`main` 只接受经 PR 的合并，规则分四层，**最外层已经是服务端强制**：

| 层 | 状态 | 内容 |
|---|---|---|
| GitHub 服务端分支保护 | ✅ **已启用（强制）** | 必须走 PR、三个必需检查、严格模式（落后需先 rebase）、线性历史、禁止强推与删除、必须解决对话；`enforce_admins=true`，**管理员也不能直推**。逐条参数见 [docs/branch-protection.md](docs/branch-protection.md) |
| 本地 git hook（`.githooks/pre-push`） | ✅ 生效 | 在推送前就挡住直推，省一次往返 |
| CI（`.github/workflows/main-guard.yml`） | ✅ 生效 | 绕过 hook 的直推会被标红留痕 |
| 人工（PR 模板） | ✅ 生效 | 自检清单与影响面确认 |

安装本地拦截（每个 clone 一次）：

```bash
git config core.hooksPath .githooks
# Linux / macOS 上还需保证 hook 可执行（Windows 无此位）
chmod +x .githooks/pre-push
```

完整流程：

```bash
git switch -c feat/backend-mqtt-subscribe
# … 改动 …
git add -A && git commit -m 'feat(backend): 接入 MQTT 订阅'
git push -u origin feat/backend-mqtt-subscribe
gh pr create --fill        # PR 模板会自动带入自检清单
gh pr merge --squash --delete-branch
```

约定：

- **合并方式统一用 squash**，保持 `main` 线性历史；PR 标题即最终提交信息，所以标题必须符合 Conventional Commits。仓库设置已强制 squash-only 并自动删除头部分支。
- 三个检查 `build` / `analyze-and-test` / `host-tests` 必须全绿才能合并，这条由服务端强制，不可绕过。
- `SKIP_MAIN_GUARD=1 git push` 只能绕过**本地 hook**，服务端仍会拒绝直推——它现在只用于出问题时的诊断，不再是一条"例外通道"。

> **应急**：确实需要直推（例如被错误提交卡住）时，管理员在 Settings → Branches 临时停用规则，
> 处理完**立刻**按 [docs/branch-protection.md](docs/branch-protection.md) §1 的表格重建。不要长期关闭。
> 早先的 `scripts/enable-branch-protection.sh` 已废弃删除——规则参数以文档为准，不再维护第二份脚本副本。

## 2. 跨端契约优先

协议是三层唯一的强耦合点，因此遵循「文档先行」：

1. 先改 `docs/protocol.md`（设备↔云）或 `docs/pairing.md`（App↔设备）。
2. 若是**不兼容**变更，提升信封 `v` 并新增主题前缀（如 `v2/...`），保留旧版本至少一个大版本周期。
3. 再分别改固件编码、后端解码、App 映射，同一 PR 内完成。
4. PR 描述必须贴出协议 diff 摘要。

判定原则：字段**含义**变了也算不兼容（例如 `speed` 从 km/h 改成 m/s）；只新增可选字段且旧端可忽略时，才算兼容。

## 3. 各层自检门槛

合并前必须全部通过（命令详见 [AGENTS.md](AGENTS.md)）：

| 层 | 必过 |
|---|---|
| `backend/` | `go build ./...`、`go vet ./...`、`go test ./...` |
| `app/` | `flutter analyze`（0 issue）、`dart format --set-exit-if-changed .`、`flutter test` |
| `firmware/` | `idf.py build` 无新增警告；纯 C 模块的 gcc 主机单测通过（命令见 firmware/README） |
| `docs/` | 链接可点，Mermaid 可渲染 |

新增业务逻辑必须带测试；只改文档的 PR 不受此限。

## 4. 代码边界（评审重点）

- **协议 DTO 只有一处定义**：后端 `internal/protocol`、固件 `main/proto`、App `core/models`，三者字段一一对应，命名与单位严格一致。
- 固件只在 `main/modem/` 内调用 AT 指令；采样任务不得阻塞在网络上。
- 后端 HTTP handler 只做解码与响应，事务逻辑在 service，SQL 只在 `store` 实现里。
- App 的 widget 不直接发请求，网络调用只在 data 层；跨 feature 只允许通过 `core/`。
- **安全红线**：绑定必须经后端核验一次性声明码；BLE 连接与 RSSI 不得作为授权或布防依据；解绑只能由服务端发起。

## 5. PR 检查清单

- [ ] 标题与提交信息符合规范，描述写清「为什么」而非「改了什么」
- [ ] 涉及协议时：`docs/` 已同步，版本号/兼容性已说明
- [ ] 新增配置项已进 `.env.example` 或 `sdkconfig.defaults`，并有默认值
- [ ] 新增错误路径有日志，且日志不含密钥、token、完整手机号
- [ ] 没有 `print` / `fmt.Println` 调试残留（Dart 用日志封装，Go 用 `slog`）
- [ ] 依赖变更已说明理由与体积影响（固件尤其注意 flash/RAM）
- [ ] 自我评审过 diff，无临时注释掉的死代码

## 6. 硬件与产线约定

- 每个设备有唯一 `deviceId`（见 `docs/hardware.md` 的命名规则），出厂时与 `claimCode` 一起写入 NVS 和 NFC 标签。
- NFC 标签内容为 NDEF URI：`https://<domain>/bind?d=<deviceId>&c=<claimCode>`，写入后**上锁只读**。
- `claimCode` 只以哈希形式存在于后端；任何环境不得留存明文（产线工站除外，且用完即销毁）。
- 固件不得硬编码云端地址，使用 `Kconfig.projbuild` 配置项。

## 7. 完成定义（Definition of Done）

功能算完成需要同时满足：代码合并、测试通过、文档同步、`docs/roadmap.md` 对应条目勾掉，
并且在真机 / 真实 broker 上验证过一次（不接受「本地能跑」作为唯一证据）。
