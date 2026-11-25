import 'package:material_ui/material_ui.dart';

import '../models/phone_models.dart';
import '../screens/provisioning_sheet.dart';
import '../state/phone_controller.dart';

Future<void> showLinePicker(
  BuildContext context,
  PhoneController controller, {
  VoidCallback? onManageNumbers,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      final grouped = <String, List<PhoneLine>>{};
      for (final line in controller.lines) {
        grouped.putIfAbsent(normalizeAccountGroup(line.group), () => []).add(line);
      }

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(
                  '选择默认出局主叫',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in grouped.entries) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Text(
                          '${entry.key} (${entry.value.length})',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                        ),
                      ),
                      for (final line in entry.value)
                        ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          leading: Icon(
                            Icons.sim_card_outlined,
                            color: line.canDial ? colors.primary : colors.onSurfaceVariant,
                          ),
                          title: Text(line.number),
                          subtitle: Text(
                            '${line.label != line.number ? '${line.label} · ' : ''}${line.statusLabel}',
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          trailing: controller.selectedLine.id == line.id
                              ? Icon(Icons.check_circle, color: colors.primary)
                              : null,
                          enabled: !controller.demoMode && line.enabled,
                          onTap: () {
                            controller.selectLine(line);
                            Navigator.of(context).pop();
                          },
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        scanAndBindProvisioning(context, controller);
                      },
                      icon: const Icon(Icons.qr_code_scanner, size: 18),
                      label: const Text('扫码添加'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        scanAndBindBatchProvisioning(context, controller);
                      },
                      icon: const Icon(Icons.burst_mode_outlined, size: 18),
                      label: const Text('批量扫码'),
                    ),
                  ),
                  if (onManageNumbers != null) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          onManageNumbers();
                        },
                        icon: const Icon(Icons.layers_outlined, size: 18),
                        label: const Text('管理号码'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
