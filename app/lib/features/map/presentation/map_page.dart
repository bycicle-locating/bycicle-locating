import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../core/providers.dart';
import '../../../core/router/main_shell.dart';
import '../../../core/theme/app_surface.dart';

class MapPage extends ConsumerWidget {
  const MapPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!PanelScrollScope.isActive(context, 0)) return const SizedBox.shrink();
    final devices = ref.watch(devicesProvider);
    final selected = ref.watch(selectedDeviceProvider);
    return ListView(
      controller: PanelScrollScope.of(context, 0),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        devices.when(
          skipLoadingOnRefresh: false,
          loading: () => const _MapLoading(),
          error: (error, _) => _RetryCard(
            title: '无法加载车辆',
            error: error,
            onRetry: () => ref.invalidate(devicesProvider),
          ),
          data: (_) => selected == null
              ? const AppSurface(
                  child: AppEmpty(
                    icon: Icons.pedal_bike,
                    title: '尚未绑定车辆',
                    message: '点击右上角 + 添加车辆。',
                  ),
                )
              : _VehicleCard(device: selected),
        ),
      ],
    );
  }
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context) => CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: () => context.push('/device'),
        child: AppSurface(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.pedal_bike,
                  size: 28, color: CupertinoTheme.of(context).primaryColor),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.label ?? device.id,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.label.resolveFrom(context))),
                    const SizedBox(height: 4),
                    Text('管理车辆',
                        style: TextStyle(
                            fontSize: 15,
                            color: CupertinoColors.secondaryLabel
                                .resolveFrom(context))),
                  ],
                ),
              ),
              Icon(CupertinoIcons.chevron_right,
                  size: 18,
                  color: CupertinoColors.tertiaryLabel.resolveFrom(context)),
            ],
          ),
        ),
      );
}

class _MapLoading extends StatelessWidget {
  const _MapLoading();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(32),
        child: CupertinoActivityIndicator(),
      );
}

class _RetryCard extends StatelessWidget {
  const _RetryCard(
      {required this.title, required this.error, required this.onRetry});

  final String title;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => AppSurface(
        child: Column(children: [
          AppEmpty(
            icon: CupertinoIcons.wifi_exclamationmark,
            title: title,
            message:
                error is ApiException ? (error as ApiException).message : null,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: CupertinoButton(onPressed: onRetry, child: const Text('重试')),
          ),
        ]),
      );
}
