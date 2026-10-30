import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 骑行记录列表。
///
/// TODO(M2): 接 `GET /v1/rides`，按月份分组，支持下拉刷新与空状态引导。
class RideListPage extends StatelessWidget {
  const RideListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('骑行记录')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.pedal_bike,
                  size: 72, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('还没有骑行记录', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '设备检测到持续移动后会自动开始记录。\n'
                '骑行切分与里程统计在后端完成（docs/roadmap.md M2）。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => context.go('/map'),
                child: const Text('回到地图'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
