import 'package:flutter_test/flutter_test.dart';
import 'package:phone/core/phone_core.dart';
import 'package:phone/models/phone_models.dart';

void main() {
  test('CoreCall.fromMap converts UTC timestamps to local time', () {
    final call = CoreCall.fromMap({
      'id': 'call-1',
      'peer': '+15550001000',
      'direction': 'incoming',
      'phase': 'active',
      'line_label': '卡线 1',
      'started_at': '2026-11-05T12:00:00Z',
      'answered_at': '2026-11-05T12:00:05Z',
      'muted': false,
      'speaker_on': true,
    });

    expect(call.startedAt.isUtc, isFalse);
    expect(call.answeredAt?.isUtc, isFalse);
    expect(
      call.startedAt.toUtc(),
      DateTime.utc(2026, 11, 5, 12, 0, 0),
    );
    expect(call.answeredAt?.difference(call.startedAt), const Duration(seconds: 5));
    expect(call.speakerOn, isTrue);

    final defaultAudioCall = CoreCall.fromMap({
      'id': 'call-default-audio',
      'peer': '+15550001001',
      'direction': 'outgoing',
      'phase': 'dialing',
      'line_label': '卡线 1',
      'started_at': '2026-11-05T12:00:00Z',
    });
    expect(defaultAudioCall.speakerOn, isFalse);
  });

  test('CoreCall toMap and fromMap preserve multi-account and AI transfer fields', () {
    final original = CoreCall(
      id: 'call-ai-1',
      peer: '+15550001999',
      direction: CallDirection.incoming,
      phase: CallPhase.incoming,
      lineLabel: '客服专线',
      startedAt: DateTime.utc(2026, 11, 23, 8, 30, 0),
      accountKey: '+15550001001@sip.example.test',
      ownNumber: '+15550001001',
      held: true,
      lineId: 'line-a',
      transferSource: 'ai',
      transferReason: '客户申请人工售后',
      gatewayCallId: 'gw-12345',
    );

    final restored = CoreCall.fromMap(original.toMap());
    expect(restored.accountKey, '+15550001001@sip.example.test');
    expect(restored.ownNumber, '+15550001001');
    expect(restored.held, isTrue);
    expect(restored.lineId, 'line-a');
    expect(restored.transferSource, 'ai');
    expect(restored.transferReason, '客户申请人工售后');
    expect(restored.gatewayCallId, 'gw-12345');
  });

  test('CallRecord JSON round-trip preserves instant, ownNumber and AI transfer metadata', () {
    final original = CallRecord(
      id: 'call-2',
      peer: '+15550002000',
      direction: CallDirection.outgoing,
      outcome: CallOutcome.completed,
      startedAt: DateTime.utc(2026, 11, 5, 13, 0, 0).toLocal(),
      lineLabel: '卡线 1',
      duration: const Duration(seconds: 12),
      ownNumber: '+15550001001',
      transferSource: 'ai',
      transferReason: '客户申请人工售后',
    );

    final restored = CallRecord.fromJson(original.toJson());
    expect(restored.startedAt.isUtc, isFalse);
    expect(restored.startedAt.toUtc(), original.startedAt.toUtc());
    expect(restored.duration, const Duration(seconds: 12));
    expect(restored.outcome, CallOutcome.completed);
    expect(restored.ownNumber, '+15550001001');
    expect(restored.transferSource, 'ai');
    expect(restored.transferReason, '客户申请人工售后');
  });

  test('CoreAccountState.fromMap maps registration to PhoneLine status', () {
    final account = CoreAccountState.fromMap({
      'account_key': '+15550001001@sip.example.test',
      'username': '+15550001001',
      'domain': 'sip.example.test',
      'registrar_uri': 'sip:sip.example.test:5061;transport=tls',
      'transport': 'tls',
      'srtp': 'mandatory',
      'label': '客服主线',
      'group': '客服组',
      'enabled': true,
      'is_default': true,
      'has_credential': true,
      'registration': 'registering',
    });

    final line = account.toPhoneLine();
    expect(line.id, '+15550001001@sip.example.test');
    expect(line.label, '客服主线');
    expect(line.number, '+15550001001');
    expect(line.group, '客服组');
    expect(line.status, LineStatus.connecting);
    expect(line.canDial, isFalse);
  });
}
