import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/session.dart';
import '../../../core/theme/app_surface.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _register = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = '请输入邮箱和密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(sessionProvider.notifier)
          .login(_email.text.trim(), _password.text, register: _register);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? e.message : '无法保存登录状态，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final title = _register ? '注册' : '登录';
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      child: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  minHeight:
                      (constraints.maxHeight - 48).clamp(0, double.infinity)),
              child: Center(
                  child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: AppSurface(
                    glass: true,
                    radius: 32,
                    padding: const EdgeInsets.all(24),
                    child: AutofillGroup(
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                    color: CupertinoTheme.of(context)
                                        .primaryColor
                                        .withValues(alpha: .12),
                                    borderRadius: BorderRadius.circular(16)),
                                child: Icon(CupertinoIcons.location_solid,
                                    size: 28,
                                    color: CupertinoTheme.of(context)
                                        .primaryColor))),
                        const SizedBox(height: 24),
                        Text(title,
                            style: const TextStyle(
                                fontSize: 28,
                                height: 1.2,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text('自行车定位',
                            style: TextStyle(
                                fontSize: 17,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context))),
                        const SizedBox(height: 32),
                        if (session.isLoading)
                          const Center(child: CupertinoActivityIndicator())
                        else if (session.hasError) ...[
                          const Text('无法恢复登录状态，请检查网络后重试'),
                          CupertinoButton(
                              onPressed: () => ref.invalidate(sessionProvider),
                              child: const Text('重试')),
                        ] else ...[
                          const Text('邮箱'),
                          const SizedBox(height: 8),
                          AppField(
                              controller: _email,
                              enabled: !_busy,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              onSubmitted: (_) => _passwordFocus.requestFocus(),
                              autocorrect: false,
                              autofillHints: const [AutofillHints.username]),
                          const SizedBox(height: 20),
                          const Text('密码'),
                          const SizedBox(height: 8),
                          AppField(
                              controller: _password,
                              focusNode: _passwordFocus,
                              textInputAction: TextInputAction.done,
                              autofillHints: [
                                _register
                                    ? AutofillHints.newPassword
                                    : AutofillHints.password
                              ],
                              enabled: !_busy,
                              obscureText: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              onSubmitted: (_) => _submit()),
                          const SizedBox(height: 24),
                          if (_error != null)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text(_error!,
                                    style: TextStyle(
                                        color: CupertinoColors.systemRed
                                            .resolveFrom(context)))),
                          AppAction(
                              label: title, busy: _busy, onPressed: _submit),
                          CupertinoButton(
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                        _register = !_register;
                                        _error = null;
                                      }),
                              child: Text(_register ? '已有账号？登录' : '创建账号')),
                        ],
                      ],
                    ))),
              )),
            ),
          );
        }),
      ),
    );
  }
}
