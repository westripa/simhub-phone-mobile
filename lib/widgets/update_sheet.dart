import 'package:material_ui/material_ui.dart';

import '../core/app_updater.dart';

Future<void> showUpdateSheet(
  BuildContext context, {
  required AppUpdaterController updater,
  required bool Function() isInCall,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _UpdateSheetContent(
      updater: updater,
      isInCall: isInCall,
    ),
  );
}

class _UpdateSheetContent extends StatelessWidget {
  const _UpdateSheetContent({
    required this.updater,
    required this.isInCall,
  });

  final AppUpdaterController updater;
  final bool Function() isInCall;

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final release = updater.availableRelease;
        final status = updater.status;
        final busy = status == AppUpdateStatus.checking ||
            status == AppUpdateStatus.downloading ||
            status == AppUpdateStatus.installing;
        final inCall = isInCall();

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.system_update_outlined, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '版本与在线更新',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  Chip(
                    label: Text('v${updater.currentVersion}'),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (release != null)
                Card(
                  color: colors.primaryContainer.withValues(alpha: 0.3),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '发现新版本 v${release.version}',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (release.size != null && release.size! > 0)
                              Text(
                                _formatBytes(release.size!),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                        if (release.notes.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            release.notes,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              else if (status == AppUpdateStatus.upToDate)
                ListTile(
                  leading: Icon(Icons.check_circle_outline, color: colors.primary),
                  title: Text('当前已是最新版本（v${updater.currentVersion}）'),
                  contentPadding: EdgeInsets.zero,
                )
              else
                ListTile(
                  leading: Icon(
                    status == AppUpdateStatus.checking
                        ? Icons.sync
                        : Icons.info_outline,
                  ),
                  title: Text(
                    status == AppUpdateStatus.checking
                        ? '正在检查新版本…'
                        : '点击下方按钮检查 GitHub Releases 最新版本',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              if (updater.errorMessage != null) ...[
                const SizedBox(height: 10),
                Card(
                  color: colors.errorContainer.withValues(alpha: 0.45),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      updater.errorMessage!,
                      style: TextStyle(color: colors.onErrorContainer, fontSize: 13),
                    ),
                  ),
                ),
              ],
              if (status == AppUpdateStatus.downloading ||
                  status == AppUpdateStatus.installing) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: updater.progress),
                const SizedBox(height: 6),
                Text(
                  status == AppUpdateStatus.installing
                      ? '正在校验 SHA-256 并调起系统安装器…'
                      : '正在下载 APK：${_formatBytes(updater.downloadedBytes)}'
                          '${updater.totalBytes != null ? ' / ${_formatBytes(updater.totalBytes!)}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy || !updater.supported
                          ? null
                          : () => updater.checkForUpdates(silent: false),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('检查更新'),
                    ),
                  ),
                  if (release != null) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: busy || inCall
                            ? null
                            : () => updater.downloadAndInstall(inCall: isInCall()),
                        icon: const Icon(Icons.download_outlined, size: 18),
                        label: Text(
                          status == AppUpdateStatus.permissionRequired
                              ? '重新发起安装'
                              : '下载并安装',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
