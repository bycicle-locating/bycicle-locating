import 'package:flutter/material.dart';

/// 主题集中在这里，页面里不要写死颜色。
class AppTheme {
  const AppTheme._();

  /// 与产品主色一致（骑行绿）。
  static const Color seed = Color(0xFF2E7D32);

  static ThemeData light() {
    return ThemeData(
      colorSchemeSeed: seed,
      useMaterial3: true,
      brightness: Brightness.light,
    );
  }

  static ThemeData dark() {
    return ThemeData(
      colorSchemeSeed: seed,
      useMaterial3: true,
      brightness: Brightness.dark,
    );
  }
}
