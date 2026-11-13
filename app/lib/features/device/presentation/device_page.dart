import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../core/providers.dart';

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
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: const CupertinoNavigationBar(middle: Text('车辆')),
      child: SafeArea(
          child: ListView(children: [
        CupertinoButton(
            onPressed: () => ref.invalidate(devicesProvider),
            child: const Text('刷新')),
        devices.when(
          skipLoadingOnRefresh: false,
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(e is ApiException ? e.message : '无法加载车辆，请重试')),
          data: (items) => items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24), child: Text('尚未绑定车辆'))
              : CupertinoListSection.insetGrouped(
                  children: items
                      .map((device) => CupertinoListTile(
                            title: Text(device.label ?? device.id),
                            subtitle: Text(device.id),
                            trailing: selected?.id == device.id
                                ? const Icon(CupertinoIcons.check_mark)
                                : null,
                            onTap: _busy
                                ? null
                                : () => ref
                                    .read(selectedDeviceIdProvider.notifier)
                                    .state = device.id,
                          ))
                      .toList()),
        ),
        if (selected != null && !devices.isLoading && !devices.hasError) ...[
          CupertinoListSection.insetGrouped(children: [
            CupertinoListTile(
                title: const Text('车型'),
                additionalInfo:
                    Text(selected.model.isEmpty ? '暂无' : selected.model)),
            CupertinoListTile(
                title: const Text('固件'),
                additionalInfo: Text(selected.firmware ?? '暂无')),
            CupertinoListTile(
                title: const Text('最后在线'),
                subtitle:
                    Text(selected.lastSeenAt?.toLocal().toString() ?? '暂无')),
          ]),
          CupertinoButton(
              onPressed: _busy ? null : () => _unbind(selected),
              child: _busy
                  ? const CupertinoActivityIndicator()
                  : const Text('解绑设备',
                      style: TextStyle(color: CupertinoColors.systemRed))),
        ],
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: const TextStyle(color: CupertinoColors.systemRed))),
        CupertinoButton.filled(
            onPressed: _busy ? null : () => context.push('/device/pair'),
            child: const Text('绑定设备')),
      ])),
    );
  }
}
