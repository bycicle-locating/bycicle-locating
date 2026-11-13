import 'package:flutter/cupertino.dart';

/// 主题集中在这里，页面里不要写死颜色。
class AppTheme {
  const AppTheme._();

  /// 与产品主色一致（骑行绿）。
  static const Color seed = Color(0xFF2E7D32);

  /// 深色模式下需要提亮，保证与深色背景的对比度。
  static const CupertinoDynamicColor primary =
      CupertinoDynamicColor.withBrightness(
    color: seed,
    darkColor: Color(0xFF66BB6A),
  );

  /// 填充按钮的前景：深色模式下亮绿底用黑字，满足 4.5:1 对比度。
  static const CupertinoDynamicColor primaryContrasting =
      CupertinoDynamicColor.withBrightness(
    color: Color(0xFFFFFFFF),
    darkColor: Color(0xFF000000),
  );

  /// 不锁 brightness，其余颜色交给 Cupertino 的系统动态色跟随明暗模式。
  static const CupertinoThemeData cupertino = CupertinoThemeData(
    primaryColor: primary,
    primaryContrastingColor: primaryContrasting,
  );

  /// 正文使用系统默认字距，保证中文和动态字体自然排版。
  static const double tracking = 0;
  static const double bodyHeight = 1.5;

  static TextStyle secondaryText(BuildContext context, {double fontSize = 13}) {
    return TextStyle(
      fontSize: fontSize,
      height: bodyHeight,
      letterSpacing: tracking,
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
    );
  }

  static TextStyle sectionHeader(BuildContext context) {
    return TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      height: 1.2,
      color: CupertinoColors.secondaryLabel.resolveFrom(context),
    );
  }
}
