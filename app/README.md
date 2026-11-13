# app

Flutter 手机端。架构约定为 **Riverpod + feature-first**。

新增或修改界面前必读 [App 视觉与交互规范](../docs/app-design-system.md)：统一设计令牌、亚克力材质、可展开底部面板、共享组件及视觉验收要求。现有页面尚未全面迁移，不应将旧页面的局部样式作为新设计基准。

> **验证状态**：✅ Flutter 3.47.9 下通过 `flutter analyze`（0 issue）、`flutter test`（26 项）、
> `dart format --set-exit-if-changed`；`flutter build apk --debug` 通过。模拟器完成公网注册、登录、会话恢复、绑定与解绑闭环。
>
> ✅ **Android 平台工程已生成**（`android/`，applicationId `top.byciclelocating.app`），可直接构建 debug APK。
> **iOS 尚未生成**；需要时执行（先把 `<org>` 换成自己的反向域名，`com.example` 之后很难改）：

```bash
cd app
flutter create --platforms=ios --org <你的域名> --project-name bkl_app .
```

`lib/` 与 `test/` 不受影响（已存在不会被覆盖）。

## 当前状态

| 部分 | 状态 |
|---|---|
| 路由（含 `/bind?d=&c=` 深链） | ✅ |
| `core/api`（dio 封装、错误归一化） | ✅ |
| `core/nfc` 的 `BindTagParser` | ✅ 有单测 |
| `core/ble` / `core/nfc` 插件接入 | ⛔ 接口 + 桩（M1） |
| 地图、骑行列表、实时位置 | ⛔ 占位页 |
| 登录 / JWT / 会话恢复 | ✅ 安全存储 + 过期处理 |
| 车辆绑定、列表、解绑 | ✅ 接入公网 API |
| 视觉规范与共享组件 | ✅ `docs/app-design-system.md`、`core/theme` |
| `android/` 平台工程 | ✅ 可构建 debug APK（applicationId `top.byciclelocating.app`） |
| `ios/` 平台工程 | ⛔ 待生成（见上） |

## 命令

```bash
flutter pub get
flutter analyze                    # 必须 0 issue（已验证）
dart format --set-exit-if-changed .
flutter test                       # 26 项，已验证

# 构建 Android debug APK
flutter build apk --debug

# Android 模拟器连本机后端：模拟器里的 127.0.0.1 是手机自己，要用 10.0.2.2
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080

# 真机连本机后端：换成电脑的局域网 IP（与手机同一网段）
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8080
```

> Debug 构建通过 `android/app/src/debug/res/xml/network_security_config.xml` 放行明文 HTTP；
> release 不包含该配置，后端必须用 HTTPS。

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
- [x] 登录与 token 持久化，移除 `Env.devUserId`
- [ ] 把心跳、告警接入 WebSocket
- [ ] Android/iOS 权限配置：`BLUETOOTH_SCAN/CONNECT`、`NSBluetoothAlwaysUsageDescription`、NFC 能力声明

## 注意

- **BLE 与 RSSI 只做 UI 提示**，不要用它判断"车是否安全"或在附近就免鉴权。
- 声明码是敏感数据：不要写日志、不要进埋点、不要显示在分享卡片里。
