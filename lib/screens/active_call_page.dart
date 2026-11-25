import 'dart:async';
import 'package:material_ui/material_ui.dart';

import '../core/phone_core.dart';
import '../models/phone_models.dart';
import '../state/phone_controller.dart';
import '../utils/format.dart';

const _dtmfKeys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];

class ActiveCallPage extends StatefulWidget {
  const ActiveCallPage({super.key, required this.controller});

  final PhoneController controller;

  @override
  State<ActiveCallPage> createState() => _ActiveCallPageState();
}

class _ActiveCallPageState extends State<ActiveCallPage> {
  bool _dtmfOpen = false;
  String _dtmfLog = '';

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final call = controller.call;
    if (call == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final incomingDirection = call.direction == CallDirection.incoming;
    final incomingPhase = call.phase == CallPhase.incoming;
    final active = call.phase == CallPhase.active;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Pill(
                      label: incomingDirection ? '来电' : '外呼',
                      color: colors.primary,
                    ),
                    _Pill(
                      label: controller.demoMode
                          ? '演示模式'
                          : (controller.registration == CoreRegistration.registered
                              ? 'SIP 已接入'
                              : 'SIP 未接入'),
                      color: colors.onSurfaceVariant,
                    ),
                    if (call.ownNumber.isNotEmpty)
                      _Pill(
                        label:
                            '${incomingDirection ? '本机接听' : '本机呼出'} · ${call.ownNumber}',
                        color: colors.primary,
                      ),
                    if (call.transferSource != null)
                      _Pill(
                        label:
                            'AI 转人工${call.transferReason != null ? ' · ${call.transferReason}' : ''}',
                        color: colors.tertiary,
                      ),
                    if (call.held && active)
                      _Pill(label: '通话已保持', color: colors.tertiary),
                  ],
                ),
              ),
              const Spacer(),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.primary.withValues(alpha: 0.1),
                  border: Border.all(
                    color: colors.primary.withValues(alpha: 0.28),
                  ),
                ),
                child: Icon(
                  incomingDirection ? Icons.phone_in_talk : Icons.phone_forwarded,
                  size: 42,
                  color: colors.primary,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '${incomingDirection ? '来电号码 · ' : ''}${phaseLabel(call.phase)}',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colors.primary,
                      letterSpacing: 1.2,
                    ),
              ),
              const SizedBox(height: 8),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  call.peer,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ),
              const SizedBox(height: 10),
              if (call.ownNumber.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.primary.withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${incomingDirection ? '打给本机：' : '本机主叫：'}${call.ownNumber}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: colors.onSurface,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                      ),
                      if (call.lineLabel.trim().isNotEmpty &&
                          call.lineLabel.trim() != call.ownNumber.trim()) ...[
                        const SizedBox(height: 2),
                        Text(
                          call.lineLabel.trim(),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ],
                  ),
                )
              else
                Text(
                  call.lineLabel,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              const SizedBox(height: 14),
              if (active)
                CallTimer(startedAt: call.answeredAt ?? call.startedAt)
              else if (incomingPhase)
                Text(
                  '接听后开始计时',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                )
              else if (controller.demoMode)
                TextButton(
                  onPressed: controller.simulateConnected,
                  child: const Text('演示：模拟接通'),
                )
              else
                Text(
                  '正在呼叫…',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              if (active && _dtmfOpen) ...[
                const SizedBox(height: 14),
                Container(
                  constraints: const BoxConstraints(maxWidth: 260),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _dtmfLog.isEmpty ? 'DTMF 按键（0-9 / * / #）' : _dtmfLog,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                      ),
                      const SizedBox(height: 8),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 2.1,
                        children: [
                          for (final d in _dtmfKeys)
                            OutlinedButton(
                              onPressed: () {
                                controller.sendDtmf(d);
                                setState(() {
                                  _dtmfLog = (_dtmfLog + d);
                                  if (_dtmfLog.length > 20) {
                                    _dtmfLog = _dtmfLog.substring(_dtmfLog.length - 20);
                                  }
                                });
                              },
                              child: Text(d),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              if (incomingPhase)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallAction(
                      label: '拒接',
                      icon: Icons.call_end,
                      color: colors.error,
                      onPressed: controller.hangup,
                    ),
                    _CallAction(
                      label: '接听',
                      icon: Icons.call,
                      color: colors.primary,
                      filled: true,
                      onPressed: controller.answer,
                    ),
                  ],
                )
              else
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 14,
                  runSpacing: 12,
                  children: [
                    _CallAction(
                      label: call.muted ? '取消静音' : '静音',
                      icon: call.muted ? Icons.mic_off : Icons.mic,
                      selected: call.muted,
                      onPressed: controller.toggleMute,
                    ),
                    if (active)
                      _CallAction(
                        label: call.held ? '恢复' : '保持',
                        icon: call.held ? Icons.play_arrow : Icons.pause,
                        selected: call.held,
                        onPressed: controller.toggleHold,
                      ),
                    if (active)
                      _CallAction(
                        label: _dtmfOpen ? '收起' : '按键',
                        icon: Icons.dialpad,
                        selected: _dtmfOpen,
                        onPressed: () => setState(() => _dtmfOpen = !_dtmfOpen),
                      ),
                    _CallAction(
                      label: '免提',
                      icon: call.speakerOn ? Icons.volume_up : Icons.volume_up_outlined,
                      selected: call.speakerOn,
                      onPressed: controller.toggleSpeaker,
                    ),
                    _CallAction(
                      label: '挂断',
                      icon: Icons.call_end,
                      color: colors.error,
                      onPressed: controller.hangup,
                    ),
                  ],
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class CallTimer extends StatefulWidget {
  const CallTimer({super.key, required this.startedAt});

  final DateTime startedAt;

  @override
  State<CallTimer> createState() => _CallTimerState();
}

class _CallTimerState extends State<CallTimer> {
  Timer? timer;
  Duration elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _tick();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    setState(() {
      elapsed = DateTime.now().difference(widget.startedAt);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      formatDuration(elapsed),
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 1.5,
          ),
    );
  }
}

class _CallAction extends StatelessWidget {
  const _CallAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.color,
    this.filled = false,
    this.selected = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;
  final bool filled;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tone = color ?? colors.onSurface;
    final background = filled
        ? tone
        : selected
            ? colors.primary.withValues(alpha: 0.16)
            : colors.surfaceContainerHigh;
    final foreground = filled
        ? colors.onPrimary
        : selected
            ? colors.primary
            : tone;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 60,
          height: 60,
          child: IconButton.filled(
            tooltip: label,
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: background,
              foregroundColor: foreground,
              shape: const CircleBorder(),
            ),
            icon: Icon(icon, size: 24),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
