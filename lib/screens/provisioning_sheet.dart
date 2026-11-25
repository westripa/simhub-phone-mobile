import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/debug_sip_config.dart';
import '../core/phone_core.dart';
import '../core/provisioning.dart';
import '../models/phone_models.dart';
import '../state/phone_controller.dart';

bool _scanInFlight = false;
DateTime? _lastScanFinishedAt;

/// Launches the built-in QR scanner with tap/re-entry debounce and binds
/// any recognized provisioning URL or configuration payload.
Future<void> scanAndBindProvisioning(
  BuildContext context,
  PhoneController controller,
) async {
  final last = _lastScanFinishedAt;
  if (_scanInFlight) return;
  if (last != null &&
      DateTime.now().difference(last) < const Duration(milliseconds: 600)) {
    return;
  }

  _scanInFlight = true;
  try {
    final raw = await controller.scanQrCode();
    if (!context.mounted) return;
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) {
      if (!shouldUseNativeCore()) {
        await showProvisioningSheet(context, controller);
      }
      return;
    }

    final normalizedUrl = unwrapProvisioningUrl(trimmed);
    final isUrl = !normalizedUrl.contains('\n') &&
        !normalizedUrl.contains('\r') &&
        (normalizedUrl.startsWith('https://') ||
            normalizedUrl.startsWith('http://'));
    if (isUrl) {
      await _importScannedUrl(context, controller, normalizedUrl);
    } else {
      await _importScannedText(context, controller, trimmed);
    }
  } finally {
    _scanInFlight = false;
    _lastScanFinishedAt = DateTime.now();
  }
}

/// Launches the continuous multi-QR scanner so users can scan multiple number
/// provisioning QR codes in one session and batch-bind them together.
Future<void> scanAndBindBatchProvisioning(
  BuildContext context,
  PhoneController controller,
) async {
  final last = _lastScanFinishedAt;
  if (_scanInFlight) return;
  if (last != null &&
      DateTime.now().difference(last) < const Duration(milliseconds: 600)) {
    return;
  }

  _scanInFlight = true;
  try {
    final rawItems = await controller.scanQrCodes();
    if (!context.mounted) return;
    if (rawItems.isEmpty) {
      if (!shouldUseNativeCore()) {
        await showProvisioningSheet(context, controller);
      }
      return;
    }

    var summary = await controller.importProvisioningBatch(rawItems);
    if (!context.mounted) return;

    if (summary.tlsFailedUrls.isNotEmpty) {
      final trustLan = await _confirmTrustSelfSignedLan(context);
      if (trustLan == true && context.mounted) {
        final retried = await controller.importProvisioningBatch(
          summary.tlsFailedUrls,
          allowSelfSignedLan: true,
        );
        summary = _mergeBatchSummaries(summary, retried);
      }
    }
    if (!context.mounted) return;
    await _showBatchSummaryFeedback(context, controller, summary);
  } finally {
    _scanInFlight = false;
    _lastScanFinishedAt = DateTime.now();
  }
}

Future<bool?> _confirmTrustSelfSignedLan(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('信任内网测试证书？'),
      content: const Text(
        '检测到内网自签 TLS 证书。仅限局域网测试环境确认信任后继续绑定。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('信任并绑定'),
        ),
      ],
    ),
  );
}

BatchProvisioningSummary _mergeBatchSummaries(
  BatchProvisioningSummary first,
  BatchProvisioningSummary retried,
) {
  final tlsSet = first.tlsFailedUrls.toSet();
  final remainingFailures = <String>[];
  final remainingInputs = <String>[];
  for (var i = 0; i < first.failedInputs.length; i++) {
    if (!tlsSet.contains(first.failedInputs[i])) {
      remainingInputs.add(first.failedInputs[i]);
      if (i < first.failures.length) remainingFailures.add(first.failures[i]);
    }
  }
  remainingFailures.addAll(retried.failures);
  remainingInputs.addAll(retried.failedInputs);
  return BatchProvisioningSummary(
    addedCount: first.addedCount + retried.addedCount,
    updatedCount: first.updatedCount + retried.updatedCount,
    totalAccounts: first.totalAccounts + retried.totalAccounts,
    boundNumbers: [...first.boundNumbers, ...retried.boundNumbers],
    failures: remainingFailures,
    tlsFailedUrls: retried.tlsFailedUrls,
    failedInputs: remainingInputs,
  );
}

String _formatBatchCounts(BatchProvisioningSummary summary) {
  final parts = <String>[];
  if (summary.addedCount > 0) parts.add('新增 ${summary.addedCount}');
  if (summary.updatedCount > 0) parts.add('更新 ${summary.updatedCount}');
  final detail = parts.isEmpty ? '' : '（${parts.join(' / ')}）';
  return '已绑定 ${summary.totalAccounts} 个号码$detail';
}

Future<void> _showBatchSummaryFeedback(
  BuildContext context,
  PhoneController controller,
  BatchProvisioningSummary summary,
) async {
  if (!summary.hasFailures) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_formatBatchCounts(summary))),
    );
    return;
  }
  if (summary.totalAccounts == 0 && summary.failedInputs.length == 1) {
    await showProvisioningSheet(
      context,
      controller,
      initialText: summary.failedInputs.first,
      initialError: summary.failures.first,
    );
    return;
  }

  final retryInSheet = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(summary.totalAccounts > 0 ? '批量导入部分成功' : '批量导入失败'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (summary.totalAccounts > 0) ...[
              Text(
                _formatBatchCounts(summary),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
            ],
            const Text(
              '以下项目未能导入：',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            for (final err in summary.failures)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $err', style: const TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('知道了'),
        ),
        if (summary.failedInputs.isNotEmpty)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('手动修正失败项'),
          ),
      ],
    ),
  );
  if (retryInSheet == true && context.mounted) {
    await showProvisioningSheet(
      context,
      controller,
      initialText: summary.failedInputs.join('\n'),
      initialError: summary.failures.join('\n'),
    );
  }
}

Future<void> _importScannedUrl(
  BuildContext context,
  PhoneController controller,
  String url,
) async {
  try {
    final result = await controller.importProvisioningUrl(url);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已成功绑定 ${result.accounts.length} 个号码')),
    );
  } on FormatException catch (error) {
    if (!context.mounted) return;
    final uri = Uri.tryParse(url);
    final tlsPromptEligible = uri != null &&
        uri.scheme.toLowerCase() == 'https' &&
        isPrivateLanHost(uri.host) &&
        error.message.contains('TLS');
    if (tlsPromptEligible) {
      final trustLan = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('信任内网测试证书？'),
          content: const Text(
            '检测到内网自签 TLS 证书。仅限局域网测试环境确认信任后继续绑定。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('信任并绑定'),
            ),
          ],
        ),
      );
      if (trustLan == true && context.mounted) {
        try {
          final retried = await controller.importProvisioningUrl(
            url,
            allowSelfSignedLan: true,
          );
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已成功绑定 ${retried.accounts.length} 个号码')),
          );
          return;
        } on FormatException catch (retryError) {
          if (!context.mounted) return;
          await showProvisioningSheet(
            context,
            controller,
            initialText: url,
            initialError: retryError.message,
          );
          return;
        }
      }
      return;
    }
    await showProvisioningSheet(
      context,
      controller,
      initialText: url,
      initialError: error.message,
    );
  } catch (error) {
    if (!context.mounted) return;
    await showProvisioningSheet(
      context,
      controller,
      initialText: url,
      initialError: '$error',
    );
  }
}

Future<void> _importScannedText(
  BuildContext context,
  PhoneController controller,
  String payload,
) async {
  try {
    final result = await controller.importProvisioningText(payload);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已成功绑定 ${result.accounts.length} 个号码')),
    );
  } on FormatException catch (error) {
    if (!context.mounted) return;
    await showProvisioningSheet(
      context,
      controller,
      initialText: payload,
      initialError: error.message,
    );
  } catch (error) {
    if (!context.mounted) return;
    await showProvisioningSheet(
      context,
      controller,
      initialText: payload,
      initialError: '$error',
    );
  }
}

Future<void> showProvisioningSheet(
  BuildContext context,
  PhoneController controller, {
  int initialTab = 0,
  String? initialText,
  String? initialError,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _ProvisioningSheet(
      controller: controller,
      initialTab: initialTab,
      initialText: initialText,
      initialError: initialError,
    ),
  );
}

class _ProvisioningSheet extends StatefulWidget {
  const _ProvisioningSheet({
    required this.controller,
    required this.initialTab,
    this.initialText,
    this.initialError,
  });

  final PhoneController controller;
  final int initialTab;
  final String? initialText;
  final String? initialError;

  @override
  State<_ProvisioningSheet> createState() => _ProvisioningSheetState();
}

class _ProvisioningSheetState extends State<_ProvisioningSheet> {
  late int _tab = widget.initialTab;
  bool _submitting = false;
  bool _allowSelfSignedLan = false;
  late String _error = widget.initialError ?? '';

  late final _provController =
      TextEditingController(text: widget.initialText ?? '');
  final _provGroupController = TextEditingController();
  final _provLabelController = TextEditingController();
  final _provRegistrarController = TextEditingController();

  final _manualRegistrarController = TextEditingController();
  final _manualDomainController = TextEditingController();
  final _manualUserController = TextEditingController();
  final _manualSecretController = TextEditingController();
  final _manualGroupController = TextEditingController();
  final _manualLabelController = TextEditingController();
  String _manualTransport = 'tls';
  String _manualSrtp = 'mandatory';

  @override
  void dispose() {
    _provController.dispose();
    _provGroupController.dispose();
    _provLabelController.dispose();
    _provRegistrarController.dispose();
    _manualRegistrarController.dispose();
    _manualDomainController.dispose();
    _manualUserController.dispose();
    _manualSecretController.dispose();
    _manualGroupController.dispose();
    _manualLabelController.dispose();
    super.dispose();
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() => _error = '剪贴板为空，请先复制配网链接。');
      return;
    }
    setState(() {
      _provController.text = text;
      _error = '';
    });
  }

  Future<void> _submitProvisioning() async {
    final raw = _provController.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请粘贴配网链接或配置文本。');
      return;
    }
    setState(() {
      _submitting = true;
      _error = '';
    });
    try {
      final batchUrls = extractProvisioningBatchLines(raw);
      if (batchUrls != null) {
        final summary = await widget.controller.importProvisioningBatch(
          batchUrls,
          groupOverride: _provGroupController.text,
          labelPrefix: _provLabelController.text,
          registrarOverride: _provRegistrarController.text,
          allowSelfSignedLan: _allowSelfSignedLan,
        );
        if (!mounted) return;
        if (summary.hasFailures) {
          if (summary.totalAccounts > 0) {
            _provController.text = summary.failedInputs.join('\n');
            setState(() {
              _error = '${_formatBatchCounts(summary)}；以下项目失败：\n${summary.failures.join('\n')}';
            });
          } else {
            setState(() => _error = summary.failures.join('\n'));
          }
          return;
        }
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_formatBatchCounts(summary))),
        );
        return;
      }

      final result = await widget.controller.importProvisioningText(
        raw,
        groupOverride: _provGroupController.text,
        labelPrefix: _provLabelController.text,
        registrarOverride: _provRegistrarController.text,
        allowSelfSignedTls: _allowSelfSignedLan,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已成功绑定 ${result.accounts.length} 个号码')),
      );
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '导入失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitManual() async {
    final rawRegistrar = _manualRegistrarController.text.trim();
    final domain = _manualDomainController.text.trim();
    final username = _manualUserController.text.trim();
    final secret = _manualSecretController.text.trim();
    if (rawRegistrar.isEmpty ||
        domain.isEmpty ||
        username.isEmpty ||
        secret.isEmpty) {
      setState(() => _error = '请填写服务器地址、域名、号码以及 HA1 或密码。');
      return;
    }
    setState(() {
      _submitting = true;
      _error = '';
    });
    try {
      final registrar = normalizeSipRegistrarUri(
        rawRegistrar,
        transportHint: _manualTransport,
      );
      final isHa1 = RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(secret);
      await widget.controller.addOrUpdateAccount(
        SipAccountConfig(
          username: username,
          authUsername: username,
          domain: domain,
          realm: domain,
          registrarUri: registrar,
          transport: _manualTransport,
          srtp: _manualSrtp,
          ha1: isHa1 ? secret.toLowerCase() : null,
          password: isHa1 ? null : secret,
          label: _manualLabelController.text.trim(),
          group: normalizeAccountGroup(_manualGroupController.text),
          enabled: true,
          allowSelfSignedTls: _allowSelfSignedLan,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存 $username')),
      );
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 16 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '导入或配置号码',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('粘贴链接 / 文本')),
                ButtonSegment(value: 1, label: Text('手动配置')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() {
                _tab = s.first;
                _error = '';
              }),
            ),
            const SizedBox(height: 12),
            if (_tab == 0) ...[
              TextField(
                controller: _provController,
                maxLines: 4,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '配网链接（支持每行一个批量导入）或 XML / linphonerc / JSON',
                  hintText: 'https://.../api/v1/provisioning/<token>',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _submitting ? null : _pasteClipboard,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('从剪贴板粘贴'),
                ),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('高级选项（分组 / 备注 / 服务器覆盖）'),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _provGroupController,
                          decoration: const InputDecoration(
                            labelText: '号码组',
                            hintText: '默认分组',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _provLabelController,
                          decoration: const InputDecoration(
                            labelText: '备注前缀',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _provRegistrarController,
                    decoration: const InputDecoration(
                      labelText: 'SIP 服务器覆盖（可选）',
                      hintText: 'sip:主机:5061;transport=tls',
                      isDense: true,
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('允许内网自签证书（仅局域网测试）'),
                    value: _allowSelfSignedLan,
                    onChanged: (v) => setState(() => _allowSelfSignedLan = v),
                  ),
                ],
              ),
            ] else ...[
              TextField(
                controller: _manualRegistrarController,
                decoration: const InputDecoration(
                  labelText: 'SIP 服务器地址',
                  hintText: 'sip:服务器:5061',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manualDomainController,
                      decoration: const InputDecoration(
                        labelText: 'SIP 域名',
                        hintText: 'webrtc.local',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _manualUserController,
                      decoration: const InputDecoration(
                        labelText: '号码 / 用户名',
                        hintText: '+15550000001',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _manualSecretController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Digest HA1（32位）或密码',
                  isDense: true,
                ),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('高级选项（分组 / 协议 / SRTP）'),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _manualGroupController,
                          decoration: const InputDecoration(
                            labelText: '号码组',
                            hintText: '默认分组',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _manualLabelController,
                          decoration: const InputDecoration(
                            labelText: '备注（可选）',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('传输:', style: Theme.of(context).textTheme.bodySmall),
                      for (final t in ['tls', 'tcp', 'udp'])
                        ChoiceChip(
                          label: Text(t.toUpperCase()),
                          selected: _manualTransport == t,
                          onSelected: (_) => setState(() {
                            _manualTransport = t;
                            if (t != 'tls' && _manualSrtp == 'mandatory') {
                              _manualSrtp = 'disabled';
                            } else if (t == 'tls') {
                              _manualSrtp = 'mandatory';
                            }
                          }),
                        ),
                      const SizedBox(width: 4),
                      Text('SRTP:', style: Theme.of(context).textTheme.bodySmall),
                      for (final s in [
                        ('mandatory', '强制'),
                        ('optional', '可选'),
                        ('disabled', '关闭'),
                      ])
                        ChoiceChip(
                          label: Text(s.$2),
                          selected: _manualSrtp == s.$1,
                          onSelected: (_) => setState(() => _manualSrtp = s.$1),
                        ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('允许内网自签证书（仅局域网测试）'),
                    value: _allowSelfSignedLan,
                    onChanged: (v) => setState(() => _allowSelfSignedLan = v),
                  ),
                ],
              ),
            ],
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error,
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ),
            FilledButton.icon(
              onPressed: _submitting
                  ? null
                  : (_tab == 0 ? _submitProvisioning : _submitManual),
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(_tab == 0 ? '解析并绑定' : '保存并连接'),
            ),
          ],
        ),
      ),
    );
  }
}
