import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/env.dart';

/// 设置页。骨架阶段只展示编译期配置，便于排查"连的是哪个后端"。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const ListTile(
            title: Text('后端地址'),
            subtitle: Text(Env.apiBaseUrl),
          ),
          const ListTile(
            title: Text('实时推送地址'),
            subtitle: Text(Env.wsBaseUrl),
          ),
          const ListTile(
            title: Text('绑定域名'),
            subtitle: Text(Env.bindHost),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('关于'),
            subtitle: Text('自行车定位与骑行记录 0.1.0（骨架）'),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '以上地址在构建时用 --dart-define 注入，不是运行时设置项。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: () => context.go('/map'),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}
