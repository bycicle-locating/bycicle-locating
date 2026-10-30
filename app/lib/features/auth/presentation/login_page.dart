import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/env.dart';

/// 登录页占位。
///
/// TODO(M1): 接后端 `POST /v1/auth/login`，成功后存 token 并注入 ApiClient。
/// 在此之前 App 用 `Env.devUserId` 走后端的开发鉴权。
class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 32),
            Icon(Icons.directions_bike,
                size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 24),
            Text('登录功能尚未接入',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              '当前使用开发身份：${Env.devUserId}\n'
              '后端 APP_ENV=dev 时会信任该身份，生产必须换成 JWT。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => context.go('/map'),
              child: const Text('以开发身份继续'),
            ),
          ],
        ),
      ),
    );
  }
}
