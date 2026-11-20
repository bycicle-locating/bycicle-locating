import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'app_surface.dart';

/// 二级任务保留背景上下文；键盘与安全区共同约束卡片可用空间。
class FloatingPage extends StatelessWidget {
  const FloatingPage({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              12, 20, 12, MediaQuery.viewInsetsOf(context).bottom + 12),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
              child: AppSurface(
                glass: true,
                radius: 32,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                    child: Row(children: [
                      Expanded(
                          child: Text(title,
                              style: const TextStyle(
                                  fontSize: 22,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600))),
                      CupertinoButton(
                        onPressed: () => context.canPop()
                            ? context.pop()
                            : context.go('/map'),
                        child: const Icon(CupertinoIcons.xmark,
                            semanticLabel: '关闭'),
                      ),
                    ]),
                  ),
                  Flexible(child: child),
                ]),
              ),
            ),
          ),
        ),
      );
}
