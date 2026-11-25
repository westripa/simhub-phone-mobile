import 'package:material_ui/material_ui.dart';

import '../core/phone_core.dart';
import '../models/phone_models.dart';
import '../state/phone_controller.dart';
import '../utils/format.dart';
import 'provisioning_sheet.dart';

const _allGroupsKey = '__all__';

class NumbersPage extends StatefulWidget {
  const NumbersPage({
    super.key,
    required this.controller,
    required this.onDialWithNumber,
  });

  final PhoneController controller;
  final VoidCallback onDialWithNumber;

  @override
  State<NumbersPage> createState() => _NumbersPageState();
}

class _NumbersPageState extends State<NumbersPage> {
  String _selectedGroup = _allGroupsKey;

  Future<void> _editMeta(CoreAccountState acc) async {
    final labelCtl = TextEditingController(text: acc.label);
    final groupCtl = TextEditingController(text: acc.group);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('编辑 ${acc.displayNumber}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: groupCtl,
              decoration: const InputDecoration(
                labelText: '所属号码组',
                hintText: '例如：客服组 / 售后组',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: labelCtl,
              decoration: const InputDecoration(
                labelText: '号码备注',
                hintText: '例如：美区主线',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true && mounted) {
      await widget.controller.updateAccountMeta(
        acc.accountKey,
        label: labelCtl.text.trim(),
        group: normalizeAccountGroup(groupCtl.text),
      );
    }
    labelCtl.dispose();
    groupCtl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ctrl = widget.controller;
    final accounts = ctrl.accounts;

    final groupCounts = <String, int>{};
    for (final acc in accounts) {
      final g = normalizeAccountGroup(acc.group);
      groupCounts[g] = (groupCounts[g] ?? 0) + 1;
    }
    final activeFilter =
        (_selectedGroup == _allGroupsKey || groupCounts.containsKey(_selectedGroup))
            ? _selectedGroup
            : _allGroupsKey;
    final visibleAccounts = activeFilter == _allGroupsKey
        ? accounts
        : accounts
            .where((a) => normalizeAccountGroup(a.group) == activeFilter)
            .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Card(
          color: colors.primaryContainer.withValues(alpha: 0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colors.primary.withValues(alpha: 0.32)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  accounts.isEmpty ? '扫码绑定第一个号码' : '扫码添加或更新号码',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '对准网关配网二维码自动识别绑定，支持多号单码、连续批量扫码叠加，内置防误触防抖。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: () => scanAndBindProvisioning(context, ctrl),
                          icon: const Icon(Icons.qr_code_scanner, size: 18),
                          label: const Text(
                            '扫码配置号码',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 46,
                        child: FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          onPressed: () => scanAndBindBatchProvisioning(context, ctrl),
                          icon: const Icon(Icons.burst_mode_outlined, size: 18),
                          label: const Text(
                            '连续批量扫码',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: () => showProvisioningSheet(
                        context,
                        ctrl,
                        initialTab: 0,
                      ),
                      icon: const Icon(Icons.link, size: 17),
                      label: const Text('粘贴配网链接'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => showProvisioningSheet(
                        context,
                        ctrl,
                        initialTab: 1,
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: const Text('手动配置'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (ctrl.demoMode) ...[
          const SizedBox(height: 10),
          Card(
            color: colors.tertiaryContainer.withValues(alpha: 0.35),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.science_outlined, color: colors.tertiary),
              title: const Text('演示模式已开启'),
              subtitle: const Text('不会发起真实 SIP 注册，导入配网后将自动退出演示。'),
              trailing: TextButton(
                onPressed: ctrl.call != null || ctrl.accounts.isEmpty
                    ? null
                    : () => ctrl.setDemoMode(false),
                child: const Text('退出演示'),
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Text(
              '已绑定号码（${accounts.length}）',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const Spacer(),
            if (accounts.isNotEmpty && !ctrl.demoMode) ...[
              if (accounts.any(
                (a) => a.enabled && a.registration != CoreRegistration.registered,
              ))
                TextButton.icon(
                  onPressed: () => ctrl.reconnectAll(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重新连接'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              const SizedBox(width: 4),
              Text(
                '${ctrl.onlineCount}/${accounts.where((a) => a.enabled).length} 在线',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        if (accounts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(
                '暂无已绑定号码，请先点击上方“扫码配置号码”。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
              ),
            ),
          )
        else ...[
          if (groupCounts.length > 1) ...[
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: Text('全部 (${accounts.length})'),
                  selected: activeFilter == _allGroupsKey,
                  onSelected: (_) =>
                      setState(() => _selectedGroup = _allGroupsKey),
                ),
                for (final entry in groupCounts.entries)
                  ChoiceChip(
                    label: Text('${entry.key} (${entry.value})'),
                    selected: activeFilter == entry.key,
                    onSelected: (_) =>
                        setState(() => _selectedGroup = entry.key),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          for (final acc in visibleAccounts) ...[
            _AccountTile(
              account: acc,
              busy: ctrl.call != null,
              onTapDefault: () => ctrl.selectDefaultAccount(acc.accountKey),
              onAction: (action) async {
                switch (action) {
                  case 'dial':
                    await ctrl.selectDefaultAccount(acc.accountKey);
                    widget.onDialWithNumber();
                  case 'edit':
                    await _editMeta(acc);
                  case 'toggle':
                    await ctrl.setAccountEnabled(acc.accountKey, !acc.enabled);
                  case 'remove':
                    await ctrl.removeAccount(acc.accountKey);
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.busy,
    required this.onTapDefault,
    required this.onAction,
  });

  final CoreAccountState account;
  final bool busy;
  final VoidCallback onTapDefault;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (statusText, statusColor) = switch (account.registration) {
      CoreRegistration.registered => ('在线', colors.primary),
      CoreRegistration.registering => ('连接中', colors.tertiary),
      CoreRegistration.failed => ('异常', colors.error),
      CoreRegistration.unregistered => (
          account.enabled ? '未注册' : '已停用',
          colors.onSurfaceVariant,
        ),
    };
    final parts = <String>[
      if (account.label.trim().isNotEmpty) account.label.trim(),
      normalizeAccountGroup(account.group),
      statusText,
    ];
    final formattedReason = formatRegistrationError(account.reason);
    final subtitle = (formattedReason != null && formattedReason.isNotEmpty)
        ? '${parts.join(' · ')}（$formattedReason）'
        : parts.join(' · ');

    return Card(
      child: ListTile(
        onTap: busy || !account.enabled ? null : onTapDefault,
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: statusColor.withValues(alpha: 0.14),
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                account.displayNumber,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (account.isDefault) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '默认主叫',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: account.registration == CoreRegistration.failed
                ? colors.error
                : colors.onSurfaceVariant,
          ),
        ),
        trailing: PopupMenuButton<String>(
          enabled: !busy,
          onSelected: onAction,
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'dial', child: Text('设为主叫并拨号')),
            const PopupMenuItem(value: 'edit', child: Text('修改备注与分组')),
            PopupMenuItem(
              value: 'toggle',
              child: Text(account.enabled ? '停用此号码' : '启用此号码'),
            ),
            PopupMenuItem(
              value: 'remove',
              child: Text('移除号码', style: TextStyle(color: colors.error)),
            ),
          ],
        ),
      ),
    );
  }
}
