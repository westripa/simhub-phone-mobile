const defaultAccountGroup = '默认分组';

String normalizeAccountGroup(String? raw) {
  final trimmed = raw?.trim() ?? '';
  return trimmed.isEmpty ? defaultAccountGroup : trimmed;
}

enum LineStatus { ready, connecting, offline, busy }

class PhoneLine {
  const PhoneLine({
    required this.id,
    required this.label,
    required this.number,
    required this.status,
    this.group = defaultAccountGroup,
    this.domain = '',
    this.enabled = true,
    this.reason,
  });

  final String id;
  final String label;
  final String number;
  final LineStatus status;
  final String group;
  final String domain;
  final bool enabled;
  final String? reason;

  bool get canDial => status == LineStatus.ready;

  String get statusLabel => switch (status) {
        LineStatus.ready => '在线',
        LineStatus.connecting => '连接中',
        LineStatus.offline => '离线',
        LineStatus.busy => '忙线',
      };
}

enum CallDirection { incoming, outgoing }

enum CallOutcome { completed, missed, rejected, cancelled, failed }

class CallRecord {
  const CallRecord({
    required this.id,
    required this.peer,
    required this.direction,
    required this.outcome,
    required this.startedAt,
    required this.lineLabel,
    this.duration,
    this.ownNumber,
    this.transferSource,
    this.transferReason,
    this.endReason,
  });

  final String id;
  final String peer;
  final CallDirection direction;
  final CallOutcome outcome;
  final DateTime startedAt;
  final String lineLabel;
  final Duration? duration;
  final String? ownNumber;
  final String? transferSource;
  final String? transferReason;
  final String? endReason;

  Map<String, Object?> toJson() => {
        'id': id,
        'peer': peer,
        'direction': direction.name,
        'outcome': outcome.name,
        'started_at': startedAt.toUtc().toIso8601String(),
        'line_label': lineLabel,
        'duration_ms': duration?.inMilliseconds,
        if (ownNumber != null && ownNumber!.isNotEmpty) 'own_number': ownNumber,
        if (transferSource != null && transferSource!.isNotEmpty)
          'transfer_source': transferSource,
        if (transferReason != null && transferReason!.isNotEmpty)
          'transfer_reason': transferReason,
        if (endReason != null && endReason!.isNotEmpty) 'end_reason': endReason,
      };

  factory CallRecord.fromJson(Map<String, Object?> map) {
    final direction = CallDirection.values.firstWhere(
      (value) => value.name == map['direction'],
      orElse: () => CallDirection.outgoing,
    );
    final outcome = CallOutcome.values.firstWhere(
      (value) => value.name == map['outcome'],
      orElse: () => CallOutcome.cancelled,
    );
    final durationMs = map['duration_ms'];
    return CallRecord(
      id: '${map['id'] ?? ''}',
      peer: '${map['peer'] ?? ''}',
      direction: direction,
      outcome: outcome,
      startedAt:
          DateTime.tryParse('${map['started_at'] ?? ''}')?.toLocal() ??
              DateTime.now(),
      lineLabel: '${map['line_label'] ?? ''}',
      duration: durationMs is num
          ? Duration(milliseconds: durationMs.toInt())
          : null,
      ownNumber: _optionalString(map['own_number']),
      transferSource: _optionalString(map['transfer_source']),
      transferReason: _optionalString(map['transfer_reason']),
      endReason: _optionalString(map['end_reason']),
    );
  }
}

enum CallPhase { dialing, ringing, active, incoming }

class CallSession {
  const CallSession({
    required this.peer,
    required this.phase,
    required this.direction,
    required this.lineLabel,
    required this.startedAt,
    this.answeredAt,
    this.muted = false,
    this.speakerOn = true,
  });

  final String peer;
  final CallPhase phase;
  final CallDirection direction;
  final String lineLabel;
  final DateTime startedAt;
  final DateTime? answeredAt;
  final bool muted;
  final bool speakerOn;

  bool get isIncoming => direction == CallDirection.incoming;
  bool get isActive => phase == CallPhase.active;

  CallSession copyWith({
    String? peer,
    CallPhase? phase,
    CallDirection? direction,
    String? lineLabel,
    DateTime? startedAt,
    DateTime? answeredAt,
    bool? muted,
    bool? speakerOn,
  }) {
    return CallSession(
      peer: peer ?? this.peer,
      phase: phase ?? this.phase,
      direction: direction ?? this.direction,
      lineLabel: lineLabel ?? this.lineLabel,
      startedAt: startedAt ?? this.startedAt,
      answeredAt: answeredAt ?? this.answeredAt,
      muted: muted ?? this.muted,
      speakerOn: speakerOn ?? this.speakerOn,
    );
  }
}

String? _optionalString(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
