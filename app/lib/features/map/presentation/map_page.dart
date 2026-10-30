import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 地图页：显示车辆最后已知位置。
///
/// TODO(M1): 接入 flutter_map + OSM 瓦片，并在显示前把 WGS-84 转成 GCJ-02
/// （后端与设备只存 WGS-84，转换只发生在展示层）。
class MapPage extends StatelessWidget {
  const MapPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的车'),
        actions: [
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined,
                  size: 72, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('地图尚未接入', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '绑定设备后，这里显示最后已知位置与在线状态。\n'
                '地图与实时轨迹见 docs/roadmap.md 的 M1。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => context.go('/device/pair'),
                icon: const Icon(Icons.nfc),
                label: const Text('绑定设备'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.go('/rides'),
                child: const Text('查看骑行记录'),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) {
          switch (index) {
            case 1:
              context.go('/rides');
            case 2:
              context.go('/device');
            default:
              break;
          }
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), label: '地图'),
          NavigationDestination(icon: Icon(Icons.pedal_bike), label: '骑行'),
          NavigationDestination(icon: Icon(Icons.bluetooth), label: '车辆'),
        ],
      ),
    );
  }
}
