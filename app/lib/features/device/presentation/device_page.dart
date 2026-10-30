import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 车辆页：绑定入口 + 近场状态 + 解绑。
///
/// 解绑只提供"车主账号发起"的入口，不提供任何设备侧操作——
/// 否则丢车后偷车者一按键就能让车脱离监控（pairing.md §1）。
class DevicePage extends StatelessWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('车辆')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.nfc),
            title: const Text('绑定设备'),
            subtitle: const Text('触碰车上的 NFC 标签完成绑定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/device/pair'),
          ),
          const Divider(height: 1),
          const ListTile(
            leading: Icon(Icons.bluetooth),
            title: Text('近场连接'),
            subtitle: Text('显示"车在附近"、触发闪灯蜂鸣（M1 接入）'),
            enabled: false,
          ),
          const ListTile(
            leading: Icon(Icons.battery_std),
            title: Text('电量与固件'),
            subtitle: Text('来自 BLE device-info（M1 接入）'),
            enabled: false,
          ),
          const ListTile(
            leading: Icon(Icons.route),
            title: Text('跟车轨迹'),
            subtitle: Text('实时位置来自 WebSocket（M1 接入）'),
            enabled: false,
          ),
          const Divider(height: 1),
          const ListTile(
            leading: Icon(Icons.link_off),
            title: Text('解绑设备'),
            subtitle: Text('只能由车主账号发起；设备按键不会解绑'),
            enabled: false,
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'BLE 只用于显示连接与"在附近"，不作为布防或解绑依据。'
              '防盗判定全部在后端用轨迹与围栏完成。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
