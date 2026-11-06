import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';

/// 地图页：显示车辆最后已知位置。
///
/// TODO(M1): 接入 flutter_map + OSM 瓦片，并在显示前把 WGS-84 转成 GCJ-02
/// （后端与设备只存 WGS-84，转换只发生在展示层）。
class MapPage extends StatelessWidget {
  const MapPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = CupertinoTheme.of(context);
    final green = theme.primaryColor;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('我的车'),
        trailing: Semantics(
          button: true,
          label: '设置',
          child: CupertinoButton(
            onPressed: () => context.push('/settings'),
            child: const Icon(CupertinoIcons.settings),
          ),
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: _MapPlaceholder(primary: green)),
          Align(
            alignment: const Alignment(0, -0.2),
            child: _LocationPin(primary: green),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _StatusCard(
                primary: green,
                onBind: () => context.push('/device/pair'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 地图占位：道路描边、建筑块、公园与水系，真实瓦片在 M1 接入。
class _MapPlaceholder extends StatelessWidget {
  const _MapPlaceholder({required this.primary});

  final Color primary;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return CustomPaint(
      painter: _MapBackgroundPainter(
        background: dark ? const Color(0xFF151517) : const Color(0xFFF4F1EA),
        road: dark ? const Color(0xFF2F2F31) : const Color(0xFFFFFFFF),
        casing: dark ? const Color(0xFF262628) : const Color(0xFFE2DED5),
        building: dark ? const Color(0xFF202022) : const Color(0xFFE8E4DC),
        park: dark ? const Color(0xFF1E3A24) : const Color(0xFFDDEBD4),
        water: dark ? const Color(0xFF16324A) : const Color(0xFFC9E2F2),
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _MapBackgroundPainter extends CustomPainter {
  const _MapBackgroundPainter({
    required this.background,
    required this.road,
    required this.casing,
    required this.building,
    required this.park,
    required this.water,
  });

  final Color background;
  final Color road;
  final Color casing;
  final Color building;
  final Color park;
  final Color water;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    // 建筑块：让空白地块有城市纹理。
    final buildingPaint = Paint()..color = building;
    final blocks = <Rect>[
      Rect.fromLTWH(w * 0.06, h * 0.07, w * 0.11, h * 0.07),
      Rect.fromLTWH(w * 0.21, h * 0.09, w * 0.09, h * 0.05),
      Rect.fromLTWH(w * 0.08, h * 0.17, w * 0.13, h * 0.07),
      Rect.fromLTWH(w * 0.36, h * 0.06, w * 0.11, h * 0.08),
      Rect.fromLTWH(w * 0.51, h * 0.09, w * 0.08, h * 0.05),
      Rect.fromLTWH(w * 0.80, h * 0.06, w * 0.13, h * 0.09),
      Rect.fromLTWH(w * 0.08, h * 0.37, w * 0.10, h * 0.06),
      Rect.fromLTWH(w * 0.36, h * 0.35, w * 0.11, h * 0.07),
      Rect.fromLTWH(w * 0.56, h * 0.35, w * 0.09, h * 0.06),
      Rect.fromLTWH(w * 0.82, h * 0.37, w * 0.11, h * 0.08),
      Rect.fromLTWH(w * 0.10, h * 0.88, w * 0.13, h * 0.05),
      Rect.fromLTWH(w * 0.36, h * 0.89, w * 0.11, h * 0.05),
      Rect.fromLTWH(w * 0.72, h * 0.89, w * 0.14, h * 0.05),
    ];
    for (final block in blocks) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(block, const Radius.circular(3)),
        buildingPaint,
      );
    }

    // 公园与水域
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.58, h * 0.08, w * 0.55, h * 0.2),
        const Radius.circular(24),
      ),
      Paint()..color = park,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-w * 0.15, h * 0.66, w * 0.45, h * 0.28),
        const Radius.circular(28),
      ),
      Paint()..color = park,
    );
    final river = Path()
      ..moveTo(w * 1.05, h * 0.42)
      ..cubicTo(w * 0.75, h * 0.48, w * 0.62, h * 0.62, w * 0.4, h * 0.58)
      ..cubicTo(w * 0.2, h * 0.54, w * 0.12, h * 0.72, -w * 0.05, h * 0.8);
    canvas.drawPath(
      river,
      Paint()
        ..color = water
        ..style = PaintingStyle.stroke
        ..strokeWidth = 26
        ..strokeCap = StrokeCap.round,
    );

    // 道路：先画描边再画路面，接近真实地图的层次。
    void drawRoad(Offset a, Offset b, double width) {
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = casing
          ..strokeWidth = width + 3
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = road
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }

    drawRoad(Offset(-w * 0.05, h * 0.3), Offset(w * 1.05, h * 0.26), 12);
    drawRoad(Offset(w * 0.22, -h * 0.05), Offset(w * 0.3, h * 1.05), 10);
    drawRoad(Offset(w * 0.72, -h * 0.05), Offset(w * 0.64, h * 1.05), 10);
    drawRoad(Offset(-w * 0.05, h * 0.78), Offset(w * 1.05, h * 0.84), 10);
    drawRoad(Offset(-w * 0.05, h * 0.46), Offset(w * 0.5, h * 0.44), 5);
    drawRoad(Offset(w * 0.46, -h * 0.05), Offset(w * 0.52, h * 0.4), 5);
    drawRoad(Offset(w * 0.86, h * 0.3), Offset(w * 0.9, h * 1.05), 5);
    drawRoad(Offset(-w * 0.05, h * 0.6), Offset(w * 0.4, h * 0.62), 5);
    drawRoad(Offset(w * 0.6, h * 0.5), Offset(w * 1.05, h * 0.52), 5);
  }

  @override
  bool shouldRepaint(covariant _MapBackgroundPainter oldDelegate) {
    return oldDelegate.background != background ||
        oldDelegate.road != road ||
        oldDelegate.casing != casing ||
        oldDelegate.building != building ||
        oldDelegate.park != park ||
        oldDelegate.water != water;
  }
}

/// 车辆标记：白圈 + 品牌绿底 + 车辆符号。
class _LocationPin extends StatelessWidget {
  const _LocationPin({required this.primary});

  final Color primary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: CupertinoColors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(5),
      child: Container(
        decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
        child: const Icon(CupertinoIcons.car_fill,
            size: 30, color: CupertinoColors.white),
      ),
    );
  }
}

/// 底部浮动状态卡：Liquid Glass 风格，承载唯一的主动作。
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.primary,
    required this.onBind,
  });

  final Color primary;
  final VoidCallback onBind;

  @override
  Widget build(BuildContext context) {
    final background = CupertinoColors.systemBackground.resolveFrom(context);
    final separator = CupertinoColors.separator.resolveFrom(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: background.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: separator),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(CupertinoIcons.car_fill, color: primary),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '尚未绑定车辆',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.15,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '绑定后显示最后位置与在线状态\n'
                          '地图与实时位置将在 M1 接入',
                          style: AppTheme.secondaryText(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: CupertinoButton.filled(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  onPressed: onBind,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.dot_radiowaves_left_right, size: 18),
                      SizedBox(width: 8),
                      Text('绑定设备'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
