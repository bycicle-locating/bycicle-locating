import 'package:flutter/cupertino.dart';

import '../../../core/env.dart';
import '../../../core/theme/app_theme.dart';

/// 设置页。骨架阶段只展示编译期配置，便于排查"连的是哪个后端"。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final headerStyle = AppTheme.sectionHeader(context);
    final footerStyle = AppTheme.secondaryText(context);
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text('设置'),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            const _AppHeader(),
            CupertinoListSection.insetGrouped(
              header: Text('环境', style: headerStyle),
              footer: Text(
                '以上地址在构建时用 --dart-define 注入，不是运行时设置项。',
                style: footerStyle,
              ),
              children: const [
                CupertinoListTile(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  title: Text(
                    '后端地址',
                    style: TextStyle(letterSpacing: 0.15),
                  ),
                  subtitle: Text(
                    Env.apiBaseUrl,
                    style: TextStyle(letterSpacing: 0.3, height: 1.3),
                  ),
                ),
                CupertinoListTile(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  title: Text(
                    '实时推送地址',
                    style: TextStyle(letterSpacing: 0.15),
                  ),
                  subtitle: Text(
                    Env.wsBaseUrl,
                    style: TextStyle(letterSpacing: 0.3, height: 1.3),
                  ),
                ),
                CupertinoListTile(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  title: Text(
                    '绑定域名',
                    style: TextStyle(letterSpacing: 0.15),
                  ),
                  subtitle: Text(
                    Env.bindHost,
                    style: TextStyle(letterSpacing: 0.3, height: 1.3),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// 应用标识卡：与启动图标一致的品牌绿方块，居中避免页面左重右轻。
class _AppHeader extends StatelessWidget {
  const _AppHeader();

  @override
  Widget build(BuildContext context) {
    final primary = CupertinoTheme.of(context).primaryColor;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 28, 16, 10),
      padding: const EdgeInsets.symmetric(vertical: 34),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground
            .resolveFrom(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [primary, primary.withValues(alpha: 0.72)],
              ),
              borderRadius: BorderRadius.circular(19),
            ),
            child: const Icon(
              CupertinoIcons.location_solid,
              size: 42,
              color: CupertinoColors.white,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '自行车定位',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '0.1.0（骨架）',
            style: AppTheme.secondaryText(context),
          ),
        ],
      ),
    );
  }
}
