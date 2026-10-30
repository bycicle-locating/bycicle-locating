# app

Flutter 手机端。架构约定为 **Riverpod + feature-first**。

> **验证状态**：✅ 已在 Flutter 3.44 / Dart 3.10（容器内）通过 `flutter analyze`（0 issue）、
> `flutter test`（8 项）、`dart format --set-exit-if-changed`。
>
> ⚠️ **还没有平台工程目录**（`android/`、`ios/` 等）。因此能分析、能跑单测，但**不能打包**。
> 首次运行前必须生成，且要先把 `<org>` 换成你自己的反向域名（`com.example` 之后很难改）：

```bash
cd app
flutter create --platforms=android,ios --org com.yourorg --project-name bkl_app .
```

生成后会多出 `android/`、`ios/` 等目录，`lib/` 与 `test/` 不受影响（已存在不会被覆盖）。

## 当前状态

| 部分 | 状态 |
|---|---|
| 路由（含 `/bind?d=&c=` 深链） | ✅ |
| `core/api`（dio 封装、错误归一化） | ✅ |
| `core/nfc` 的 `BindTagParser` | ✅ 有单测 |
| `core/ble` / `core/nfc` 插件接入 | ⛔ 接口 + 桩（M1） |
| 地图、骑行列表、实时位置 | ⛔ 占位页 |
| 登录 / JWT | ⛔ 开发身份（M1） |
| `android/`、`ios/` 平台工程 | ⛔ 需用 `flutter create` 生成（见上） |

## 命令

```bash
flutter pub get
flutter analyze                    # 必须 0 issue（已验证）
dart format --set-exit-if-changed .
flutter test                       # 8 项，已验证

# 连本机后端（默认就是 127.0.0.1:8080，可省略）
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8080
```

## 结构

```
lib/
  main.dart                 ProviderScope 入口
  app.dart                  MaterialApp.router + 主题
  core/
    env.dart                编译期配置（--dart-define）与近场阈值
    log.dart                日志封装（禁止裸 print）
    providers.dart          ApiClient / BleClient / NfcReader 的注入点
    api/api_client.dart     REST 调用 + DioException → ApiException
    ble/ble_client.dart     BLE 接口与桩实现
    nfc/nfc_reader.dart     NFC 接口 + NDEF URI 解析（纯函数，可测）
    router/app_router.dart  go_router 路由表
    theme/app_theme.dart
  features/
    map/ ride/ device/ auth/ settings/
test/
  bind_tag_parser_test.dart
```

## 分层规则

1. **feature-first**：新功能在 `features/<name>/` 下自成一块，内部可再分
   `data/`（repository、DTO）、`domain/`（模型）、`presentation/`（页面与 provider）。
2. **跨 feature 只经 `core/`**。`features/map` 不许 import `features/ride` 的内部文件。
3. **widget 不发请求**：网络调用只出现在 `data/` 层或 provider 里，页面 watch provider。
4. **单位转换只在展示层**：后端存 m/s，UI 显示 km/h；坐标存 WGS-84，显示前转 GCJ-02。
5. **不引入代码生成**：骨架阶段模型手写。要做 `freezed`/`json_serializable` 时，
   同步更新 `.gitignore`（已预置 `*.g.dart`、`*.freezed.dart`）与 `analysis_options.yaml`。

## 待办（M1）

- [ ] 接 `nfc_manager`：`readBindTag()` 读 NDEF URI，交给现有 `BindTagParser`
- [ ] 接 `flutter_blue_plus`：实现 `BleClient.watchStatus`，含 MTU 协商与分片（pairing.md §5.3）
- [ ] 接 `flutter_map` + 轨迹回放，含 WGS-84 → GCJ-02
- [ ] 登录与 token 持久化，移除 `Env.devUserId`
- [ ] 把心跳、告警接入 WebSocket
- [ ] Android/iOS 权限配置：`BLUETOOTH_SCAN/CONNECT`、`NSBluetoothAlwaysUsageDescription`、NFC 能力声明

## 注意

- **BLE 与 RSSI 只做 UI 提示**，不要用它判断"车是否安全"或在附近就免鉴权。
- 声明码是敏感数据：不要写日志、不要进埋点、不要显示在分享卡片里。
