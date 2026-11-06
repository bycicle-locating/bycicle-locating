import 'package:flutter/cupertino.dart';

import '../../../core/theme/app_theme.dart';

/// 骑行记录列表。
///
/// TODO(M2): 接 `GET /v1/rides`，按月份分组，支持下拉刷新与空状态引导。
class RideListPage extends StatelessWidget {
  const RideListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final headerStyle = AppTheme.sectionHeader(context);
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      child: CustomScrollView(
        slivers: [
          const CupertinoSliverNavigationBar(
            largeTitle: Text('骑行记录'),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
                  child: Text('本周', style: headerStyle),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: _WeekCard(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
                  child: Text('记录', style: headerStyle),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: _EmptyCard(),
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

/// 本周概览：没有记录时展示 0，而不是留白。
class _WeekCard extends StatelessWidget {
  const _WeekCard();

  @override
  Widget build(BuildContext context) {
    final separator = CupertinoColors.separator.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground
            .resolveFrom(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            const Expanded(child: _Stat(value: '0', unit: '次', label: '骑行')),
            _divider(separator),
            const Expanded(
              child: _Stat(value: '0.0', unit: 'km', label: '里程'),
            ),
            _divider(separator),
            const Expanded(
              child: _Stat(value: '0', unit: '分钟', label: '时长'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider(Color color) {
    return Container(width: 1, height: 44, color: color);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.unit, required this.label});

  final String value;
  final String unit;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
            const SizedBox(width: 3),
            Text(unit, style: AppTheme.secondaryText(context, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 4),
        Text(label, style: AppTheme.secondaryText(context, fontSize: 12)),
      ],
    );
  }
}

/// 空状态收进卡片，避免整页只剩一句居中文案。
class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    final primary = CupertinoTheme.of(context).primaryColor;
    final pillBackground = CupertinoColors.systemGrey6.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 36, 32, 32),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground
            .resolveFrom(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              CupertinoIcons.clock_fill,
              size: 30,
              color: primary,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '还没有骑行记录',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.15,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '设备检测到持续移动后会自动开始记录。\n骑行切分与里程统计在后端完成。',
            textAlign: TextAlign.center,
            style: AppTheme.secondaryText(context),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: pillBackground,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'M2 接入后可用',
              style: AppTheme.secondaryText(context, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
