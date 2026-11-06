import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';

/// 车辆页：绑定入口 + 近场状态 + 解绑。
///
/// 解绑只提供"车主账号发起"的入口，不提供任何设备侧操作——
/// 否则丢车后偷车者一按键就能让车脱离监控（pairing.md §1）。
class DevicePage extends StatelessWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final headerStyle = AppTheme.sectionHeader(context);
    final footerStyle = AppTheme.secondaryText(context);
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      child: CustomScrollView(
        slivers: [
          const CupertinoSliverNavigationBar(
            largeTitle: Text('车辆'),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _BindCard(
                    onTap: () => context.push('/device/pair'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
                  child: Text('车辆状态', style: headerStyle),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: _MetricsCard(),
                ),
                CupertinoListSection.insetGrouped(
                  header: Text('功能', style: headerStyle),
                  children: const [
                    _FeatureTile(
                      icon: CupertinoIcons.bluetooth,
                      color: CupertinoColors.systemBlue,
                      title: '近场连接',
                      subtitle: '显示"车在附近"、触发闪灯蜂鸣',
                      trailing: 'M1',
                    ),
                    _FeatureTile(
                      icon: CupertinoIcons.location,
                      color: CupertinoColors.systemPurple,
                      title: '跟车轨迹',
                      subtitle: '实时位置来自 WebSocket',
                      trailing: 'M1',
                    ),
                  ],
                ),
                CupertinoListSection.insetGrouped(
                  header: Text('账号', style: headerStyle),
                  footer: Text(
                    'BLE 只用于显示连接与"在附近"，不作为布防或解绑依据。'
                    '防盗判定全部在后端用轨迹与围栏完成。',
                    style: footerStyle,
                  ),
                  children: const [
                    _FeatureTile(
                      icon: CupertinoIcons.xmark_circle,
                      color: CupertinoColors.systemRed,
                      title: '解绑设备',
                      subtitle: '只能由车主账号发起；设备按键不会解绑',
                      trailingIcon: CupertinoIcons.lock,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部绑定卡：比普通列表行更醒目，承载本页唯一的主动作。
class _BindCard extends StatelessWidget {
  const _BindCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = CupertinoTheme.of(context).primaryColor;
    final label = CupertinoColors.label.resolveFrom(context);
    final tertiary = CupertinoColors.tertiaryLabel.resolveFrom(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground
            .resolveFrom(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: CupertinoButton(
        padding: const EdgeInsets.all(24),
        pressedOpacity: 0.7,
        onPressed: onTap,
        child: Row(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(CupertinoIcons.car_fill, size: 34, color: primary),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '尚未绑定车辆',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.15,
                      color: label,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '触碰车上的 NFC 标签完成绑定',
                    style: AppTheme.secondaryText(context),
                  ),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, size: 18, color: tertiary),
          ],
        ),
      ),
    );
  }
}

/// 车辆状态仪表：未绑定时显示占位符，绑定后替换为真实数据。
class _MetricsCard extends StatelessWidget {
  const _MetricsCard();

  @override
  Widget build(BuildContext context) {
    final separator = CupertinoColors.separator.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 26),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground
            .resolveFrom(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            const Expanded(
              child: _Metric(
                icon: CupertinoIcons.battery_75_percent,
                color: CupertinoColors.systemGreen,
                label: '电量',
              ),
            ),
            _divider(separator),
            const Expanded(
              child: _Metric(
                icon: CupertinoIcons.antenna_radiowaves_left_right,
                color: CupertinoColors.systemBlue,
                label: '信号',
              ),
            ),
            _divider(separator),
            const Expanded(
              child: _Metric(
                icon: CupertinoIcons.clock,
                color: CupertinoColors.systemPurple,
                label: '最后在线',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider(Color color) {
    return Container(width: 1, height: 48, color: color);
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.color,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon,
            size: 20, color: CupertinoDynamicColor.resolve(color, context)),
        const SizedBox(height: 8),
        const Text(
          '—',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: AppTheme.secondaryText(context, fontSize: 12)),
      ],
    );
  }
}

/// iOS 设置风格的彩色图标块 + 文本行；用尾部状态说明替代整行置灰。
class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.trailingIcon,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? trailing;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      leadingSize: 29,
      leading: Container(
        width: 29,
        height: 29,
        decoration: BoxDecoration(
          color: CupertinoDynamicColor.resolve(color, context),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(icon, size: 17, color: CupertinoColors.white),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 17, letterSpacing: 0.15),
      ),
      subtitle: Text(subtitle, style: AppTheme.secondaryText(context)),
      trailing: trailingIcon != null
          ? Icon(
              trailingIcon,
              size: 16,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            )
          : Text(
              trailing ?? '',
              style: AppTheme.secondaryText(context),
            ),
    );
  }
}
