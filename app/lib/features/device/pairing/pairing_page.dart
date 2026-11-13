import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_client.dart';
import '../../../core/log.dart';
import '../../../core/providers.dart';
import '../../../core/theme/app_theme.dart';

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

  Future<void> _scanNfc() async {
    setState(() => _error = null);
    try {
      final tag = await ref.read(nfcReaderProvider).readBindTag();
      if (!mounted) {
        return;
      }
      if (tag == null) {
        setState(() => _error = '未读到有效的绑定标签');
        return;
      }
      setState(() {
        _deviceIdController.text = tag.deviceId;
        _claimController.text = tag.claimCode;
      });
    } on UnsupportedError catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _error = e.message);
    }
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
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text('绑定设备'),
      ),
      child: SafeArea(
        child:
            bound == null ? _buildForm(context) : _buildSuccess(context, bound),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final headerStyle = AppTheme.sectionHeader(context);
    final footerStyle = AppTheme.secondaryText(context);
    final editable = !_busy;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _Hero(),
        CupertinoListSection.insetGrouped(
          header: Text('设备信息', style: headerStyle),
          footer: Text(
            '声明码在设备未绑定期间有效；设备已绑定时再次触碰会提示已绑定，'
            '车主解绑后恢复可用。',
            style: footerStyle,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Column(
                children: [
                  const _FieldLabel('设备编号'),
                  const SizedBox(height: 10),
                  CupertinoTextField(
                    controller: _deviceIdController,
                    enabled: editable,
                    placeholder: 'BKL-2026-000123',
                    style: const TextStyle(
                      fontSize: 17,
                      letterSpacing: 0.2,
                    ),
                    placeholderStyle: TextStyle(
                      letterSpacing: 0.2,
                      color:
                          CupertinoColors.placeholderText.resolveFrom(context),
                    ),
                    clearButtonMode: OverlayVisibilityMode.editing,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _claimFocus.requestFocus(),
                  ),
                  const SizedBox(height: 24),
                  const _FieldLabel('声明码'),
                  const SizedBox(height: 10),
                  CupertinoTextField(
                    controller: _claimController,
                    focusNode: _claimFocus,
                    enabled: editable,
                    placeholder: '16 位字符',
                    style: const TextStyle(
                      fontSize: 17,
                      letterSpacing: 0.2,
                    ),
                    placeholderStyle: TextStyle(
                      letterSpacing: 0.2,
                      color:
                          CupertinoColors.placeholderText.resolveFrom(context),
                    ),
                    clearButtonMode: OverlayVisibilityMode.editing,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (_canSubmit && !_busy) {
                        _submit();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  CupertinoIcons.exclamationmark_circle,
                  size: 18,
                  color: CupertinoColors.systemRed.resolveFrom(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 13,
                      height: AppTheme.bodyHeight,
                      letterSpacing: AppTheme.tracking,
                      color: CupertinoColors.systemRed.resolveFrom(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: CupertinoButton.filled(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  onPressed: (_busy || !_canSubmit) ? null : _submit,
                  child: _busy
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            ),
                            SizedBox(width: 8),
                            Text('绑定中…'),
                          ],
                        )
                      : const Text('确认绑定'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: CupertinoButton.tinted(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  onPressed: _busy ? null : _scanNfc,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.dot_radiowaves_left_right, size: 18),
                      SizedBox(width: 8),
                      Text('触碰 NFC 读取'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess(BuildContext context, DeviceView device) {
    final green = CupertinoColors.systemGreen.resolveFrom(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 56, 24, 36),
      children: [
        Center(
          child: Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              color: green.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              CupertinoIcons.check_mark_circled_solid,
              size: 52,
              color: green,
            ),
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          '绑定成功',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.15,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '${device.id}\n设备下次联网即收到确认指令；若长时间未联网，'
          '这里会一直显示"等待设备确认"。',
          textAlign: TextAlign.center,
          style: AppTheme.secondaryText(context, fontSize: 15),
        ),
        const SizedBox(height: 40),
        CupertinoButton.filled(
          padding: const EdgeInsets.symmetric(vertical: 16),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/map'),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 页面顶部：说明主要入口是触碰标签，手动输入只是兜底。
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final primary = CupertinoTheme.of(context).primaryColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 28),
      child: Column(
        children: [
          Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              CupertinoIcons.dot_radiowaves_left_right,
              size: 48,
              color: primary,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            '触碰标签完成绑定',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.15,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '用手机靠近车上的 NFC 标签；也可以手动输入标签上的信息。',
            textAlign: TextAlign.center,
            style: AppTheme.secondaryText(context, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

/// 字段标签：占位符会随输入消失，不能替代标签。
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: AppTheme.sectionHeader(context),
      ),
    );
  }
}
