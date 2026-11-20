import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_surface.dart';

class PanelScrollScope extends InheritedWidget {
  const PanelScrollScope(
      {super.key,
      required this.controller,
      required this.activeIndex,
      required super.child});
  final ScrollController controller;
  final int activeIndex;
  static ScrollController? of(BuildContext context, int index) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<PanelScrollScope>();
    return scope?.activeIndex == index ? scope?.controller : null;
  }

  @override
  bool updateShouldNotify(PanelScrollScope oldWidget) =>
      controller != oldWidget.controller ||
      activeIndex != oldWidget.activeIndex;
}

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _sheet = DraggableScrollableController();
  double _dragStartY = 0;
  double _dragStartSize = .5;
  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!_sheet.isAttached) return;
    _sheet.animateTo(_sheet.size > .7 ? .50 : .94,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return CupertinoPageScaffold(
      child: Stack(children: [
        Positioned.fill(
            child: DecoratedBox(
                decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [
                      Color(0xFF172C2C),
                      Color(0xFF12191F),
                      Color(0xFF273036)
                    ]
                  : const [
                      Color(0xFFDDEAE6),
                      Color(0xFFE9EEF0),
                      Color(0xFFC9D8D4)
                    ]),
        ))),
        SafeArea(child: LayoutBuilder(builder: (context, mapConstraints) {
          return AnimatedBuilder(
              animation: _sheet,
              builder: (context, _) {
                final size = _sheet.isAttached ? _sheet.size : .5;
                final visibleHeight =
                    (mapConstraints.maxHeight * (1 - size) - 8)
                        .clamp(0.0, mapConstraints.maxHeight);
                final opacity = ((visibleHeight - 120) / 80).clamp(0.0, 1.0);
                if (visibleHeight < 40) return const SizedBox.shrink();
                return IgnorePointer(
                    child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                            height: visibleHeight,
                            child: Center(
                                child: Opacity(
                                    opacity: opacity,
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(CupertinoIcons.location,
                                              size: 30,
                                              color: CupertinoColors
                                                  .secondaryLabel
                                                  .resolveFrom(context)),
                                          const SizedBox(height: 10),
                                          Text('地图暂不可用',
                                              style: TextStyle(
                                                  fontSize: 15,
                                                  color: CupertinoColors
                                                      .secondaryLabel
                                                      .resolveFrom(context))),
                                        ]))))));
              });
        })),
        SafeArea(child: LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxHeight < 600 ||
              MediaQuery.textScalerOf(context).scale(17) > 24;
          final collapsed =
              ((89 + 56 * MediaQuery.textScalerOf(context).scale(22) / 22) /
                      (constraints.maxHeight - 16))
                  .clamp(.10, .70);
          return Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: DraggableScrollableSheet(
                controller: _sheet,
                initialChildSize: compact ? .94 : .50,
                minChildSize: collapsed,
                maxChildSize: .94,
                snap: true,
                snapAnimationDuration: const Duration(milliseconds: 300),
                snapSizes: [collapsed, if (collapsed < .50) .50, .94],
                builder: (context, scrollController) => AppSurface(
                    glass: true,
                    radius: 32,
                    child: Column(children: [
                      Semantics(
                          button: true,
                          label: '展开或收起面板',
                          child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _toggle,
                              onVerticalDragStart: (details) {
                                _dragStartY = details.globalPosition.dy;
                                _dragStartSize =
                                    _sheet.isAttached ? _sheet.size : .5;
                              },
                              onVerticalDragUpdate: (details) {
                                if (_sheet.isAttached) {
                                  _sheet.jumpTo((_dragStartSize -
                                          (details.globalPosition.dy -
                                                  _dragStartY) /
                                              (constraints.maxHeight - 16))
                                      .clamp(collapsed, .94));
                                }
                              },
                              onVerticalDragEnd: (_) {
                                if (!_sheet.isAttached) return;
                                final sizes = [
                                  collapsed,
                                  if (collapsed < .50) .50,
                                  .94
                                ];
                                sizes.sort((a, b) => (a - _sheet.size)
                                    .abs()
                                    .compareTo((b - _sheet.size).abs()));
                                _sheet.animateTo(sizes.first,
                                    duration:
                                        MediaQuery.disableAnimationsOf(context)
                                            ? Duration.zero
                                            : const Duration(milliseconds: 300),
                                    curve: Curves.easeOutCubic);
                              },
                              child: SizedBox(
                                  height: 28,
                                  width: double.infinity,
                                  child: Center(
                                      child: Container(
                                          width: 36,
                                          height: 5,
                                          decoration: BoxDecoration(
                                              color: CupertinoColors.systemGrey3
                                                  .resolveFrom(context),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      3))))))),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: SizedBox(
                          height: 56 *
                              MediaQuery.textScalerOf(context).scale(22) /
                              22,
                          child: Row(children: [
                            Expanded(
                                child: Text(
                                    const [
                                      '我的车',
                                      '骑行记录',
                                      '设置'
                                    ][widget.navigationShell.currentIndex],
                                    style: const TextStyle(
                                        fontSize: 22,
                                        height: 1.25,
                                        fontWeight: FontWeight.w600))),
                            if (widget.navigationShell.currentIndex == 0)
                              CupertinoButton(
                                  padding: const EdgeInsets.all(12),
                                  onPressed: () => context.push('/device/pair'),
                                  child: const Icon(CupertinoIcons.plus,
                                      size: 24, semanticLabel: '绑定设备')),
                          ]),
                        ),
                      ),
                      Expanded(
                          child: ClipRect(
                              child: PanelScrollScope(
                                  activeIndex:
                                      widget.navigationShell.currentIndex,
                                  controller: scrollController,
                                  child: widget.navigationShell))),
                      Container(
                          height: .5,
                          color:
                              CupertinoColors.separator.resolveFrom(context)),
                      CupertinoTabBar(
                        height: 60,
                        backgroundColor: CupertinoColors.transparent,
                        border: null,
                        currentIndex: widget.navigationShell.currentIndex,
                        onTap: (index) =>
                            widget.navigationShell.goBranch(index),
                        items: const [
                          BottomNavigationBarItem(
                              icon: Icon(CupertinoIcons.map), label: '地图'),
                          BottomNavigationBarItem(
                              icon: Icon(CupertinoIcons.clock), label: '骑行'),
                          BottomNavigationBarItem(
                              icon: Icon(CupertinoIcons.gear), label: '设置'),
                        ],
                      ),
                    ])),
              ));
        })),
      ]),
    );
  }
}
