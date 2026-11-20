import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/floating_page.dart';

class DevicePage extends ConsumerStatefulWidget {
  const DevicePage({super.key});
  @override
  ConsumerState<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends ConsumerState<DevicePage> {
  bool _busy = false;
  String? _error;

  Future<void> _unbind(DeviceView device) async {
    final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
              title: const Text('解绑车辆？'),
              content:
                  Text('${device.label ?? device.id}\n解绑后，持有标签声明码的人可以重新绑定。'),
              actions: [
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                CupertinoDialogAction(
                    isDestructiveAction: true,
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('解绑')),
              ],
            ));
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(deviceActionsProvider).unbind(device.id);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);
    final target = ref.watch(selectedTelemetryTargetProvider);
    return FloatingPage(
      title: '车辆管理',
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            devices.when(
              skipLoadingOnRefresh: false,
              loading: () => const Padding(
                  padding: EdgeInsets.all(32),
                  child: CupertinoActivityIndicator()),
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
              data: (items) => items.isEmpty
                  ? const AppSurface(
                      child: AppEmpty(
                          icon: Icons.pedal_bike,
                          title: '尚未绑定车辆',
                          message: '点击右上角 + 添加车辆。'))
                  : AppSurface(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [
                        for (final device in items) ...[
                          CupertinoListTile(
                            title: Text(device.label ?? device.id),
                            subtitle: Text(device.id),
                            trailing: selected?.id == device.id
                                ? Icon(CupertinoIcons.check_mark,
                                    color:
                                        CupertinoTheme.of(context).primaryColor)
                                : null,
                            onTap: _busy
                                ? null
                                : () => ref
                                    .read(selectedDeviceIdProvider.notifier)
                                    .state = device.id,
                          ),
                          if (device != items.last)
                            Container(
                                height: .5,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                color: CupertinoColors.separator
                                    .resolveFrom(context)),
                        ],
                      ])),
            ),
            if (selected != null &&
                !devices.isLoading &&
                !devices.hasError) ...[
              if (target != null) ...[
                const SizedBox(height: 16),
                _TelemetryStatus(target: target),
              ],
              const SizedBox(height: 16),
              AppSurface(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: [
                    CupertinoListTile(
                        title: const Text('车型'),
                        additionalInfo: Text(
                            selected.model.isEmpty ? '暂无' : selected.model)),
                    CupertinoListTile(
                        title: const Text('固件'),
                        additionalInfo: Text(selected.firmware ?? '暂无')),
                    CupertinoListTile(
                        title: const Text('最后在线'),
                        subtitle: Text(
                            selected.lastSeenAt?.toLocal().toString() ?? '暂无')),
                  ])),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: CupertinoColors.systemRed
                                .resolveFrom(context)))),
              const SizedBox(height: 8),
              CupertinoButton(
                  onPressed: _busy ? null : () => _unbind(selected),
                  child: _busy
                      ? const CupertinoActivityIndicator()
                      : Text('解绑车辆',
                          style: TextStyle(
                              color: CupertinoColors.systemRed
                                  .resolveFrom(context)))),
            ],
          ],
        ),
      ),
    );
  }
}

class _TelemetryStatus extends ConsumerWidget {
  const _TelemetryStatus({required this.target});

  final DeviceTelemetryTarget target;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(deviceTelemetryProvider(target))
      .when(
        loading: () => const Padding(
          padding: EdgeInsets.all(32),
          child: CupertinoActivityIndicator(),
        ),
        error: (error, _) => AppSurface(
          child: Column(children: [
            AppEmpty(
              icon: CupertinoIcons.wifi_exclamationmark,
              title: '无法加载位置',
              message: error is ApiException ? error.message : null,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: CupertinoButton(
                onPressed: () => refreshDeviceTelemetry(ref, target),
                child: const Text('重试'),
              ),
            ),
          ]),
        ),
        data: (data) {
          final latest = data.current;
          if (latest == null) {
            return const AppSurface(
              child: AppEmpty(
                icon: CupertinoIcons.location,
                title: '暂无位置',
                message: '车辆上报后会显示在这里。',
              ),
            );
          }
          return AppSurface(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              CupertinoListTile(
                title: const Text('上报时间'),
                additionalInfo: Text(_localTime(latest.ts)),
              ),
              CupertinoListTile(
                title: const Text('车速'),
                additionalInfo:
                    Text('${(latest.speedMps * 3.6).toStringAsFixed(1)} km/h'),
              ),
            ]),
          );
        },
      );
}

String _localTime(DateTime utc) {
  final time = utc.toLocal();
  String twoDigits(int n) => n.toString().padLeft(2, '0');
  return '${twoDigits(time.month)}-${twoDigits(time.day)} '
      '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
}
