import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

/// 三个一级 tab 的骨架：底部导航常驻，分支栈由 go_router 管理。
///
/// 一级页（地图/骑行/车辆）之间用 `goBranch` 切换，不产生返回栈；
/// 绑定、设置等二级页走 `push`，覆盖本骨架并自带返回箭头。
class MainShell extends StatelessWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Column(
        children: [
          Expanded(child: navigationShell),
          CupertinoTabBar(
            height: 64,
            currentIndex: navigationShell.currentIndex,
            onTap: (index) => navigationShell.goBranch(index),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.map_fill),
                label: '地图',
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.clock_fill),
                label: '骑行',
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.car_fill),
                label: '车辆',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
