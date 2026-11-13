import '../../../core/router/main_shell.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_surface.dart';

class MapPage extends ConsumerWidget {
  const MapPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);
    return ListView(
      controller: PanelScrollScope.of(context, 0),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        devices.when(
          skipLoadingOnRefresh: false,
          loading: () => const Padding(
              padding: EdgeInsets.all(32), child: CupertinoActivityIndicator()),
          error: (e, _) => AppSurface(
              child: Column(children: [
            const AppEmpty(
                icon: CupertinoIcons.wifi_exclamationmark, title: '无法加载车辆'),
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: CupertinoButton(
                    onPressed: () => ref.invalidate(devicesProvider),
                    child: const Text('重试'))),
          ])),
          data: (_) => selected == null
              ? const AppSurface(
                  child: AppEmpty(
                      icon: Icons.pedal_bike,
                      title: '尚未绑定车辆',
                      message: '点击右上角 + 添加车辆。'))
              : Semantics(
                  button: true,
                  label: '管理车辆',
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => context.push('/device'),
                    child: AppSurface(
                        padding: const EdgeInsets.all(20),
                        child: Row(children: [
                          Icon(Icons.pedal_bike,
                              size: 28,
                              color: CupertinoTheme.of(context).primaryColor),
                          const SizedBox(width: 16),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(selected.label ?? selected.id,
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                        color: CupertinoColors.label
                                            .resolveFrom(context))),
                                const SizedBox(height: 4),
                                Text('暂无位置',
                                    style: TextStyle(
                                        fontSize: 15,
                                        color: CupertinoColors.secondaryLabel
                                            .resolveFrom(context))),
                              ])),
                          Icon(CupertinoIcons.chevron_right,
                              size: 18,
                              color: CupertinoColors.tertiaryLabel
                                  .resolveFrom(context)),
                        ])),
                  )),
        ),
      ],
    );
  }
}
