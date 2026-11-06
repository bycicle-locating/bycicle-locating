import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';

/// 应用根组件。只负责主题与路由，不放业务状态。
class BklApp extends ConsumerWidget {
  const BklApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return CupertinoApp.router(
      title: '自行车定位',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.cupertino,
      routerConfig: router,
      // 当前只有中文文案；补上系统字符串（文本选择菜单、返回按钮等）的中文。
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN')],
      builder: (context, child) => DefaultTextStyle.merge(
        style: const TextStyle(letterSpacing: AppTheme.tracking),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
