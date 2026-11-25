import 'package:material_ui/material_ui.dart';

import '../models/phone_models.dart';
import '../state/phone_controller.dart';
import '../utils/format.dart';
import '../widgets/line_picker.dart';
import 'provisioning_sheet.dart';

const _keys = <(String, String)>[
  ('1', ''),
  ('2', 'ABC'),
  ('3', 'DEF'),
  ('4', 'GHI'),
  ('5', 'JKL'),
  ('6', 'MNO'),
  ('7', 'PQRS'),
  ('8', 'TUV'),
  ('9', 'WXYZ'),
  ('*', ''),
  ('0', '+'),
  ('#', ''),
];

class DialerPage extends StatelessWidget {
  const DialerPage({
    super.key,
    required this.controller,
    this.onOpenNumbers,
  });

  final PhoneController controller;
  final VoidCallback? onOpenNumbers;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final line = controller.selectedLine;

        return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _CallerPill(
                    controller: controller,
                    line: line,
                    onTap: controller.needsBinding
                        ? () => showProvisioningSheet(context, controller)
                        : () => showLinePicker(
                              context,
                              controller,
                              onManageNumbers: onOpenNumbers,
                            ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => scanAndBindProvisioning(context, controller),
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: const Text('扫码配网'),
              ),
            ],
          ),
          if (controller.needsBinding) ...[
            const SizedBox(height: 14),
            _UnboundOnboardingCard(
              onScan: () => scanAndBindProvisioning(context, controller),
              onPaste: () => showProvisioningSheet(context, controller),
            ),
          ] else if (controller.demoMode) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.tertiaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.science_outlined, size: 16, color: colors.tertiary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '演示模式 · 不拨真实电话',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => scanAndBindProvisioning(context, controller),
                    child: const Text('扫码绑真号'),
                  ),
                ],
              ),
            ),
          ],
          SizedBox(height: controller.needsBinding ? 14 : 18),
          if (controller.callNotice != null) ...[
            _CallNoticeCard(
              notice: controller.callNotice!,
              onRedial: () {
                final target = controller.callNotice!.peer;
                controller.dismissCallNotice();
                controller.setNumber(target);
              },
              onDismiss: controller.dismissCallNotice,
            ),
            const SizedBox(height: 12),
          ],
          Container(
            constraints: const BoxConstraints(minHeight: 70),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Expanded(
                  child: controller.number.isEmpty
                      ? Text(
                          '输入电话号码',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: colors.onSurfaceVariant,
                                fontWeight: FontWeight.w400,
                              ),
                        )
                      : FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            controller.number,
                            key: const ValueKey('dial-number'),
                            maxLines: 1,
                            style: Theme.of(context)
                                .textTheme
                                .displaySmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.5,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ),
                ),
                if (controller.number.isNotEmpty)
                  IconButton(
                    tooltip: '退格',
                    onPressed: controller.backspace,
                    icon: const Icon(Icons.backspace_outlined),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.56,
            children: [
              for (final key in _keys)
                _DialKey(
                  digit: key.$1,
                  letters: key.$2,
                  onPressed: () => controller.appendDigit(key.$1),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Center(
            child: SizedBox(
              width: 196,
              height: 54,
              child: FilledButton.icon(
                onPressed: controller.canDial
                    ? () => controller.dial().catchError((_) {})
                    : null,
                icon: const Icon(Icons.call),
                label: Text(
                  controller.needsBinding
                      ? '请先绑定号码'
                      : (!line.canDial ? '线路不可用' : '呼叫'),
                ),
              ),
            ),
          ),
          if (controller.needsBinding && controller.number.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '当前尚未绑定通话号码，请先点击上方“扫码绑定号码”。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.tertiary,
                    ),
              ),
            )
          else if (!controller.needsBinding && !line.canDial)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                () {
                  final errText = formatRegistrationError(line.reason);
                  return '主叫状态为${line.statusLabel}${errText != null ? '（$errText）' : ''}';
                }(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
              ),
            ),
        ],
      ),
    );
      },
    );
  }
}

class _UnboundOnboardingCard extends StatelessWidget {
  const _UnboundOnboardingCard({
    required this.onScan,
    required this.onPaste,
  });

  final VoidCallback onScan;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.primaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.primary.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: colors.primary.withValues(alpha: 0.16),
                  child: Icon(Icons.qr_code_2_rounded, color: colors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '尚未绑定通话号码',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '请扫描网关配网二维码完成绑定，绑定后即可拨打和接听电话。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onScan,
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('扫码绑定号码'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onPaste,
                  child: const Text('粘贴配网链接'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CallerPill extends StatelessWidget {
  const _CallerPill({
    required this.controller,
    required this.line,
    required this.onTap,
  });

  final PhoneController controller;
  final PhoneLine line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dotColor = controller.needsBinding
        ? colors.tertiary
        : switch (line.status) {
            LineStatus.ready => colors.primary,
            LineStatus.connecting || LineStatus.busy => colors.tertiary,
            LineStatus.offline => colors.error,
          };
    final labelText = controller.needsBinding
        ? '未绑定号码'
        : (controller.demoMode ? '本地演示' : line.number);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                labelText,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.expand_more,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _DialKey extends StatelessWidget {
  const _DialKey({
    required this.digit,
    required this.letters,
    required this.onPressed,
  });

  final String digit;
  final String letters;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return OutlinedButton(
      key: ValueKey('dial-key-$digit'),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 6),
        backgroundColor: colors.surfaceContainer,
        side: BorderSide(color: colors.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            digit,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
          if (letters.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              letters,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    letterSpacing: 1.2,
                    height: 1,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CallNoticeCard extends StatelessWidget {
  const _CallNoticeCard({
    required this.notice,
    required this.onRedial,
    required this.onDismiss,
  });

  final CallBannerNotice notice;
  final VoidCallback? onRedial;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final backgroundColor =
        notice.isWarning ? colors.tertiaryContainer : colors.errorContainer;
    final foregroundColor =
        notice.isWarning ? colors.onTertiaryContainer : colors.onErrorContainer;
    final accentColor = notice.isWarning ? colors.tertiary : colors.error;
    final heading = notice.peer.trim().isEmpty
        ? notice.title
        : '${notice.title} · ${notice.peer}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              notice.isWarning
                  ? Icons.info_outline_rounded
                  : Icons.error_outline_rounded,
              color: accentColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  heading,
                  style: textTheme.titleSmall?.copyWith(
                    color: foregroundColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (notice.message.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    notice.message,
                    style: textTheme.bodySmall?.copyWith(
                      color: foregroundColor.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onRedial != null)
            TextButton(
              onPressed: onRedial,
              style: TextButton.styleFrom(
                foregroundColor: accentColor,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重拨'),
            ),
          IconButton(
            onPressed: onDismiss,
            tooltip: '关闭提醒',
            icon: Icon(Icons.close, size: 18, color: foregroundColor),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}
