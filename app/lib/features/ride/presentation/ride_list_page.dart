import '../../../core/router/main_shell.dart';
import 'package:flutter/cupertino.dart';
import '../../../core/theme/app_surface.dart';

class RideListPage extends StatelessWidget {
  const RideListPage({super.key});
  @override
  Widget build(BuildContext context) => ListView(
          controller: PanelScrollScope.of(context, 1),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: const [
            AppSurface(
                child: AppEmpty(icon: CupertinoIcons.clock, title: '暂无骑行记录')),
          ]);
}
