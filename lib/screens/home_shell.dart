import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/call_history_store.dart';
import '../core/debug_sip_config.dart';
import '../core/native_phone_core.dart';
import '../core/phone_core.dart';
import '../state/phone_controller.dart';
import 'active_call_page.dart';
import 'dialer_page.dart';
import 'history_page.dart';
import 'numbers_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    this.core,
    this.historyStore,
  });

  final PhoneCore? core;
  final CallHistoryStore? historyStore;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final PhoneController controller;
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
  }

  @override
  void dispose() {
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
                      }
                    },
                    itemBuilder: (context) => [
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
      body: IndexedStack(
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
              isLabelVisible: controller.needsBinding,
              child: const Icon(Icons.layers_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: controller.needsBinding,
              child: const Icon(Icons.layers),
            ),
            label: '号码',
          ),
        ],
      ),
    );
  }
}
