import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/env.dart';
import '../../../core/router/main_shell.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_surface.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
        controller: PanelScrollScope.of(context, 2),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          AppSurface(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                Icon(CupertinoIcons.location_solid,
                    size: 32, color: CupertinoTheme.of(context).primaryColor),
                const SizedBox(width: 16),
                const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('自行车定位',
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w600)),
                      SizedBox(height: 4),
                      Text('版本 0.1.0', style: TextStyle(fontSize: 15)),
                    ])),
              ])),
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            const AppSurface(
                child: CupertinoListTile(
                    title: Text('API 地址'),
                    subtitle: Text(Env.apiBaseUrl,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13)))),
          ],
          const SizedBox(height: 24),
          AppAction(
              label: '退出登录',
              onPressed: () => ref.read(sessionProvider.notifier).logout()),
        ],
      );
}
