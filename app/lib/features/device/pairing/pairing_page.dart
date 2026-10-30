import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/log.dart';
import '../../../core/providers.dart';

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

  bool _busy = false;
  String? _error;
  DeviceView? _bound;

  @override
  void initState() {
    super.initState();
    _deviceIdController =
        TextEditingController(text: widget.initialDeviceId ?? '');
    _claimController =
        TextEditingController(text: widget.initialClaimCode ?? '');
  }

  @override
  void dispose() {
    _deviceIdController.dispose();
    _claimController.dispose();
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
    final deviceId = _deviceIdController.text.trim();
    // 声明码在标签里是大写 Base32，用户手输时大小写不敏感。
    final claimCode = _claimController.text.trim().toUpperCase();
    if (deviceId.isEmpty || claimCode.isEmpty) {
      setState(() => _error = '请填写设备编号与声明码');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final device = await ref.read(apiClientProvider).bindDevice(
            deviceId: deviceId,
            claimCode: claimCode,
          );
      logInfo('绑定成功', device.id);
      if (!mounted) {
        return;
      }
      setState(() => _bound = device);
    } on ApiException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('绑定设备')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('用手机触碰车上的标签', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    '标签里存着一次性的绑定声明码。绑定成功后声明码立即作废，'
                    '同一张标签无法再绑定第二台手机。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _deviceIdController,
            decoration: const InputDecoration(
              labelText: '设备编号',
              hintText: 'BKL-2026-000123',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _claimController,
            decoration: const InputDecoration(
              labelText: '声明码',
              hintText: '16 位字符，来自标签',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_bound != null) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.check_circle),
                title: const Text('绑定成功'),
                subtitle: Text(
                  '${_bound!.id} 已绑定。设备下次联网即收到确认指令；'
                  '若长时间未联网，这里会一直显示"等待设备确认"。',
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _busy ? null : _scanNfc,
            icon: const Icon(Icons.nfc),
            label: const Text('触碰 NFC 读取'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('确认绑定'),
          ),
        ],
      ),
    );
  }
}
