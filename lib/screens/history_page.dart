import 'package:material_ui/material_ui.dart';

import '../models/phone_models.dart';
import '../state/phone_controller.dart';
import '../utils/format.dart';

enum HistoryFilter { all, missed }

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.controller,
    required this.onSelectNumber,
    required this.onClear,
  });

  final PhoneController controller;
  final ValueChanged<String> onSelectNumber;
  final VoidCallback onClear;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  HistoryFilter filter = HistoryFilter.all;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final all = widget.controller.history;
    final missed = all.where((item) =>
        item.outcome == CallOutcome.missed ||
        item.outcome == CallOutcome.failed ||
        item.outcome == CallOutcome.rejected);
    final records = filter == HistoryFilter.all ? all : missed.toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<HistoryFilter>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: HistoryFilter.all,
                      label: Text('全部 ${all.length}'),
                    ),
                    ButtonSegment(
                      value: HistoryFilter.missed,
                      label: Text('未接 ${missed.length}'),
                    ),
                  ],
                  selected: {filter},
                  onSelectionChanged: (value) {
                    setState(() => filter = value.first);
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '清空通话记录',
                onPressed: all.isEmpty ? null : _confirmClear,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        Expanded(
          child: records.isEmpty
              ? _EmptyHistory(
                  title: filter == HistoryFilter.all ? '还没有通话记录' : '没有未接来电',
                  description: filter == HistoryFilter.all
                      ? '完成一次外呼或接听来电后，记录会出现在这里。'
                      : '当前筛选下没有未接、失败或拒接记录。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: records.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final record = records[index];
                    final bad = record.outcome == CallOutcome.missed ||
                        record.outcome == CallOutcome.failed ||
                        record.outcome == CallOutcome.rejected;
                    final iconColor = bad ? colors.error : colors.primary;
                    final hasOwn = record.ownNumber != null && record.ownNumber!.trim().isNotEmpty;
                    final ownNum = hasOwn ? record.ownNumber!.trim() : '';
                    final ownLabel = hasOwn
                        ? '${record.direction == CallDirection.incoming ? '呼入至' : '主叫'} $ownNum'
                        : '';
                    final remark = record.lineLabel.trim();
                    final labelPart = (remark.isNotEmpty && remark != ownNum)
                        ? (ownLabel.isNotEmpty ? ' · $remark' : remark)
                        : '';
                    final lineSummary = '$ownLabel$labelPart';
                    final aiTag = record.transferSource != null
                        ? (record.transferReason != null &&
                                record.transferReason!.trim().isNotEmpty
                            ? 'AI转人工（${record.transferReason!.trim()}）'
                            : 'AI转人工')
                        : '';
                    final metaParts = <String>[
                      if (lineSummary.isNotEmpty) lineSummary,
                      if (aiTag.isNotEmpty) aiTag,
                      outcomeLabelFor(record.outcome, record.direction),
                      formatHistoryTime(record.startedAt),
                      if (record.duration != null) formatDuration(record.duration!),
                    ];
                    return Card(
                      child: ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        leading: CircleAvatar(
                          radius: 20,
                          backgroundColor: iconColor.withValues(alpha: 0.12),
                          child: Icon(
                            record.direction == CallDirection.incoming
                                ? Icons.call_received
                                : Icons.call_made,
                            color: iconColor,
                            size: 19,
                          ),
                        ),
                        title: Text(
                          record.peer,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              metaParts.join(' · '),
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                            if (record.endReason != null &&
                                record.endReason!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  record.endReason!,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: record.outcome ==
                                                CallOutcome.rejected
                                            ? colors.tertiary
                                            : colors.error,
                                      ),
                                ),
                              ),
                          ],
                        ),
                        trailing: IconButton(
                          tooltip: '回拨',
                          onPressed: () => widget.onSelectNumber(record.peer),
                          icon: Icon(Icons.call_outlined, color: colors.primary),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空通话记录？'),
        content: const Text('只清空本机通话记录，不影响网关侧历史。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onClear();
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 44, color: colors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
