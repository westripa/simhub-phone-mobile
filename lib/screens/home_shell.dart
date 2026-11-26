import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/app_updater.dart';
import '../core/call_history_store.dart';
import '../core/debug_sip_config.dart';
import '../core/native_phone_core.dart';
import '../core/phone_core.dart';
import '../state/phone_controller.dart';
import '../widgets/update_sheet.dart';
import 'active_call_page.dart';
import 'dialer_page.dart';
import 'history_page.dart';
import 'numbers_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    this.core,
    this.historyStore,
    this.updater,
  });

  final PhoneCore? core;
  final CallHistoryStore? historyStore;
  final AppUpdaterController? updater;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final PhoneController controller;
  late final AppUpdaterController updater;
  bool _ownsUpdater = false;
  bool _updateBannerDismissed = false;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    final useNative = shouldUseNativeCore();
    final resolvedCore = widget.core ?? (useNative ? NativePhoneCore() : null);
    controller = PhoneController(
      core: resolvedCore,
      historyStore:
          widget.historyStore ?? (useNative ? NativeCallHistoryStore() : null),
    )..addListener(_refresh);
    unawaited(controller.start());

    if (widget.updater != null) {
      updater = widget.updater!;
    } else {
      _ownsUpdater = true;
      updater = useNative ? AppUpdaterController() : AppUpdaterController.disabled();
    }
    updater.addListener(_refresh);
    if (useNative) {
      unawaited(updater.initVersion());
      unawaited(
        Future<void>.delayed(const Duration(seconds: 3), () async {
          if (!mounted || controller.call != null) return;
          await updater.checkForUpdates(silent: true);
        }),
      );
    }
  }

  @override
  void dispose() {
    updater.removeListener(_refresh);
    if (_ownsUpdater) updater.dispose();
    controller
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _selectNumber(String number) {
    controller.setNumber(number);
    setState(() => tab = 0);
  }

  void _openNumbers() => setState(() => tab = 2);

  void _openDialer() => setState(() => tab = 0);

  @override
  Widget build(BuildContext context) {
    final call = controller.call;
    if (call != null) {
      return ActiveCallPage(controller: controller);
    }

    return Scaffold(
      appBar: tab == 0
          ? null
          : AppBar(
              title: Text(tab == 1 ? '通话记录' : '号码管理'),
              actions: [
                if (tab == 2)
                  PopupMenuButton<String>(
                    tooltip: '更多操作',
                    onSelected: (value) async {
                      switch (value) {
                        case 'toggle_demo':
                          if (controller.demoMode &&
                              controller.accounts.isEmpty) {
                            await controller.setDemoMode(false).catchError((_) {});
                          } else {
                            await controller.setDemoMode(!controller.demoMode);
                          }
                        case 'sim_normal':
                          controller.simulateIncoming(aiTransfer: false);
                        case 'sim_ai':
                          controller.simulateIncoming(aiTransfer: true);
                        case 'check_update':
                          await showUpdateSheet(
                            context,
                            updater: updater,
                            isInCall: () => controller.call != null,
                          );
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'check_update',
                        child: Text(
                          updater.hasUpdate
                              ? '发现新版本 v${updater.availableRelease!.version}'
                              : '检查应用更新（v${updater.currentVersion}）',
                        ),
                      ),
                      if (!controller.demoMode || controller.accounts.isNotEmpty)
                        PopupMenuItem(
                          value: 'toggle_demo',
                          child: Text(
                            controller.demoMode ? '退出本地演示模式' : '开启本地演示模式',
                          ),
                        ),
                      if (controller.demoMode) ...[
                        const PopupMenuItem(
                          value: 'sim_normal',
                          child: Text('模拟普通来电'),
                        ),
                        const PopupMenuItem(
                          value: 'sim_ai',
                          child: Text('模拟 AI 转人工来电'),
                        ),
                      ],
                    ],
                  ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1),
                child: Divider(
                  height: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
      body: Column(
        children: [
          if (updater.hasUpdate && !_updateBannerDismissed)
            SafeArea(
              bottom: false,
              top: tab == 0,
              child: Material(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.system_update_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '发现新版本 v${updater.availableRelease!.version}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => showUpdateSheet(
                          context,
                          updater: updater,
                          isInCall: () => controller.call != null,
                        ),
                        child: const Text('升级'),
                      ),
                      IconButton(
                        tooltip: '稍后提醒',
                        icon: const Icon(Icons.close, size: 18),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _updateBannerDismissed = true),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: tab,
              children: [
                DialerPage(
                  controller: controller,
                  onOpenNumbers: _openNumbers,
                ),
                HistoryPage(
                  controller: controller,
                  onSelectNumber: _selectNumber,
                  onClear: controller.clearHistory,
                ),
                NumbersPage(
                  controller: controller,
                  onDialWithNumber: _openDialer,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.dialpad_outlined),
            selectedIcon: Icon(Icons.dialpad),
            label: '拨号',
          ),
          const NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: '记录',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: controller.needsBinding || updater.hasUpdate,
              child: const Icon(Icons.layers_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: controller.needsBinding || updater.hasUpdate,
              child: const Icon(Icons.layers),
            ),
            label: '号码',
          ),
        ],
      ),
    );
  }
}
