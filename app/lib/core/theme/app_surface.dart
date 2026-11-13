import 'dart:ui';
import 'package:flutter/cupertino.dart';

/// 浮层统一使用一种材质；内部内容使用实色，避免叠加模糊。
class AppSurface extends StatelessWidget {
  const AppSurface(
      {super.key,
      required this.child,
      this.glass = false,
      this.radius = 24,
      this.padding = EdgeInsets.zero});
  final Widget child;
  final bool glass;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final opaque = MediaQuery.highContrastOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final color = glass
        ? (dark ? const Color(0xFF252A30) : const Color(0xFFF7F8FA))
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: glass && !opaque ? .90 : 1),
        borderRadius: BorderRadius.circular(radius),
        border: glass
            ? Border.all(
                color:
                    CupertinoColors.white.withValues(alpha: dark ? .08 : .45),
                width: .5)
            : null,
      ),
      child: Padding(padding: padding, child: child),
    );
    return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: glass && !opaque
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: content)
            : content);
  }
}

class AppAction extends StatelessWidget {
  const AppAction(
      {super.key, required this.label, this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => SizedBox(
      width: double.infinity,
      child: CupertinoButton.filled(
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        onPressed: busy ? null : onPressed,
        child: busy ? const CupertinoActivityIndicator() : Text(label),
      ));
}

/// 所有输入框的唯一形状来源：与主按钮同为圆角，使用系统填充色。
class AppField extends StatelessWidget {
  const AppField(
      {super.key,
      required this.controller,
      this.placeholder,
      this.focusNode,
      this.enabled = true,
      this.obscureText = false,
      this.keyboardType,
      this.textInputAction,
      this.autofillHints,
      this.onSubmitted,
      this.autocorrect = false,
      this.enableSuggestions = true,
      this.textCapitalization = TextCapitalization.none});
  final TextEditingController controller;
  final String? placeholder;
  final FocusNode? focusNode;
  final bool enabled, obscureText, autocorrect, enableSuggestions;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) => CupertinoTextField(
        controller: controller,
        focusNode: focusNode,
        placeholder: placeholder,
        enabled: enabled,
        obscureText: obscureText,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        autofillHints: autofillHints,
        onSubmitted: onSubmitted,
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        textCapitalization: textCapitalization,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        style: const TextStyle(fontSize: 17),
        decoration: BoxDecoration(
          color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
        ),
      );
}

class AppEmpty extends StatelessWidget {
  const AppEmpty(
      {super.key, required this.icon, required this.title, this.message});
  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 36, color: CupertinoTheme.of(context).primaryColor),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    color:
                        CupertinoColors.secondaryLabel.resolveFrom(context))),
          ],
        ]),
      );
}

class AppHeading extends StatelessWidget {
  const AppHeading(this.title, {super.key, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 20),
        child: Row(children: [
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w600, height: 1.2))),
          if (action != null) action!,
        ]),
      );
}
