import '../../../core/theme/floating_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../core/log.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_surface.dart';

/// 绑定页。
///
/// 正常情况下入口是 NFC 触碰（`/bind?d=&c=`），此时两个字段已预填；
/// 手动输入只是兜底，方便客服与产线验证。真正的授权判定在**后端**，
/// 本页不做任何"看起来像授权"的本地判断。
class PairingPage extends ConsumerStatefulWidget {
  const PairingPage({super.key, this.initialDeviceId, this.initialClaimCode});

  final String? initialDeviceId;
  final String? initialClaimCode;

  @override
  ConsumerState<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends ConsumerState<PairingPage> {
  late final TextEditingController _deviceIdController;
  late final TextEditingController _claimController;
  final FocusNode _claimFocus = FocusNode();

  bool _busy = false;
  String? _error;
  DeviceView? _bound;

  bool get _canSubmit =>
      _deviceIdController.text.trim().isNotEmpty &&
      _claimController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _deviceIdController =
        TextEditingController(text: widget.initialDeviceId ?? '');
    _claimController =
        TextEditingController(text: widget.initialClaimCode ?? '');
    _deviceIdController.addListener(_onInputChanged);
    _claimController.addListener(_onInputChanged);
  }

  void _onInputChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _deviceIdController.removeListener(_onInputChanged);
    _claimController.removeListener(_onInputChanged);
    _deviceIdController.dispose();
    _claimController.dispose();
    _claimFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_canSubmit) {
      return;
    }
    final deviceId = _deviceIdController.text.trim();
    // 声明码在标签里是大写 Base32，用户手输时大小写不敏感。
    final claimCode = _claimController.text.trim().toUpperCase();

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final device =
          await ref.read(deviceActionsProvider).bind(deviceId, claimCode);
      logInfo('绑定成功', device.id);
      if (!mounted) {
        return;
      }
      FocusScope.of(context).unfocus();
      HapticFeedback.mediumImpact();
      setState(() => _bound = device);
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      HapticFeedback.heavyImpact();
      setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bound = _bound;
    return FloatingPage(
        title: '添加你的车辆',
        child: bound == null
            ? _buildForm(context)
            : _buildSuccess(context, bound));
  }

  Widget _buildForm(BuildContext context) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('设备编号'),
          const SizedBox(height: 8),
          AppField(
              controller: _deviceIdController,
              enabled: !_busy,
              placeholder: 'BKL-2026-000123',
              autocorrect: false,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _claimFocus.requestFocus()),
          const SizedBox(height: 20),
          const Text('声明码'),
          const SizedBox(height: 8),
          AppField(
              controller: _claimController,
              focusNode: _claimFocus,
              enabled: !_busy,
              placeholder: '16 位字符',
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              onSubmitted: (_) {
                if (_canSubmit && !_busy) _submit();
              }),
        ]),
        const SizedBox(height: 16),
        Text('请核对车身编号与标签上的声明码。',
            style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.secondaryLabel.resolveFrom(context))),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!,
                  style: TextStyle(
                      color: CupertinoColors.systemRed.resolveFrom(context)))),
        const SizedBox(height: 24),
        AppAction(
            label: '确认绑定', busy: _busy, onPressed: _canSubmit ? _submit : null),
      ]));

  Widget _buildSuccess(BuildContext context, DeviceView device) =>
      SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(children: [
            AppSurface(
                child: AppEmpty(
                    icon: CupertinoIcons.check_mark_circled,
                    title: '绑定成功',
                    message: device.id)),
            const SizedBox(height: 24),
            AppAction(
                label: '完成',
                onPressed: () =>
                    context.canPop() ? context.pop() : context.go('/map')),
          ]));
}
