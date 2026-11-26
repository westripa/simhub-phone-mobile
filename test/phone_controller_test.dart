import 'package:flutter_test/flutter_test.dart';
import 'package:phone/core/call_history_store.dart';
import 'package:phone/core/fake_phone_core.dart';
import 'package:phone/core/phone_core.dart';
import 'package:phone/core/provisioning.dart';
import 'package:phone/models/phone_models.dart';
import 'package:phone/state/phone_controller.dart';
import 'package:phone/utils/format.dart';

class _MemoryHistoryStore implements CallHistoryStore {
  List<CallRecord> saved = [];

  @override
  Future<List<CallRecord>> load() async => saved;

  @override
  Future<void> save(List<CallRecord> records) async {
    saved = List.of(records);
  }
}

SipAccountConfig _sampleAccount({
  required String username,
  bool enabled = true,
  String label = '',
  String group = '默认分组',
}) {
  return SipAccountConfig(
    username: username,
    authUsername: username,
    domain: 'sip.example.test',
    registrarUri: 'sip:sip.example.test:5061;transport=tls',
    transport: 'tls',
    srtp: 'mandatory',
    ha1: '0123456789abcdef0123456789abcdef',
    label: label,
    group: group,
    enabled: enabled,
  );
}

void main() {
  test('fresh controller with no accounts prompts binding and disables dialing', () async {
    final controller = PhoneController(history: []);
    await controller.start();

    expect(controller.needsBinding, isTrue);
    expect(controller.demoMode, isFalse);
    expect(controller.selectedLine.id, 'unbound');

    controller.appendDigit('1');
    controller.appendDigit('0');
    controller.appendDigit('0');
    expect(controller.canDial, isFalse);
  });

  test('call history is persisted across controller starts', () async {
    final store = _MemoryHistoryStore();
    final first = PhoneController(historyStore: store);
    await first.start();
    await first.setDemoMode(true);

    first.appendDigit('1');
    first.appendDigit('0');
    first.appendDigit('0');
    await first.dial();
    first.simulateConnected();
    await first.hangup();
    await Future<void>.delayed(Duration.zero);

    expect(store.saved, hasLength(1));

    final second = PhoneController(historyStore: store);
    await second.start();
    expect(second.history, hasLength(1));
    expect(second.history.first.peer, '100');
  });

  test('dial, answer and hangup create a completed record in demo mode', () async {
    final controller = PhoneController(history: []);
    await controller.start();
    await controller.setDemoMode(true);

    controller.appendDigit('9');
    controller.appendDigit('1');
    controller.appendDigit('9');
    controller.appendDigit('6');
    expect(controller.canDial, isTrue);

    await controller.dial();
    expect(controller.call, isNotNull);
    expect(controller.number, isEmpty);

    controller.simulateConnected();
    expect(controller.call?.phase, CallPhase.active);

    await controller.hangup();
    expect(controller.call, isNull);
    expect(controller.history.first.peer, '9196');
    expect(controller.history.first.outcome, CallOutcome.completed);
  });

  test('offline line disables dialing', () async {
    final core = FakePhoneCore(
      initialAccounts: [
        _sampleAccount(
          username: '+15550001001',
          enabled: false,
          label: '停用测试号',
        ),
      ],
    );
    final controller = PhoneController(core: core, history: []);
    await controller.start();

    controller.appendDigit('1');
    expect(controller.demoMode, isFalse);
    expect(controller.needsBinding, isFalse);
    expect(controller.selectedLine.status, LineStatus.offline);
    expect(controller.canDial, isFalse);
  });

  test('unanswered incoming call distinguishes remote missed vs local rejected', () async {
    final core = FakePhoneCore();
    final controller = PhoneController(core: core, history: []);
    await controller.start();
    await controller.setDemoMode(true);

    controller.simulateIncoming();
    expect(controller.call?.phase, CallPhase.incoming);
    await controller.hangup();
    expect(controller.history.first.outcome, CallOutcome.rejected);
    expect(controller.history.first.direction, CallDirection.incoming);

    core.simulateIncoming(peer: '10086');
    core.simulateRemoteEnd(code: 487, reason: 'Request Terminated');
    expect(controller.history.first.outcome, CallOutcome.missed);
    expect(controller.history.first.direction, CallDirection.incoming);
  });

  test('importing provisioning accounts fulfills binding and keeps existing numbers online', () async {
    final controller = PhoneController(history: []);
    await controller.start();
    expect(controller.needsBinding, isTrue);

    await controller.importProvisioningText('''
{
  "sip_proxy": "<sip:sip.example.test:5061;transport=tls>;lr",
  "accounts": [
    {
      "sip_username": "c_phone_3001",
      "number": "+15550003001",
      "domain": "sip.example.test",
      "ha1": "0123456789abcdef0123456789abcdef",
      "label": "一号线",
      "group": "客服组"
    }
  ]
}
''');

    expect(controller.needsBinding, isFalse);
    expect(controller.demoMode, isFalse);
    expect(controller.accounts, hasLength(1));
    expect(controller.accounts.first.accountKey, 'c_phone_3001@sip.example.test');
    expect(controller.accounts.first.displayNumber, '+15550003001');
    expect(controller.selectedLine.number, '+15550003001');
    expect(controller.accounts.first.registration, CoreRegistration.registered);

    await controller.importProvisioningText('''
{
  "sip_proxy": "<sip:sip.example.test:5061;transport=tls>;lr",
  "sip_username": "+15550003002",
  "domain": "sip.example.test",
  "ha1": "fedcba9876543210fedcba9876543210",
  "label": "二号线",
  "group": "售后组"
}
''');

    expect(controller.accounts, hasLength(2));
    expect(controller.onlineCount, 2);

    await controller.removeAccount('c_phone_3001@sip.example.test');
    await controller.removeAccount('+15550003002@sip.example.test');
    expect(controller.needsBinding, isTrue);
  });

  test('updateAccountMeta, selectDefaultAccount, setAccountEnabled, toggleHold and AI transfer', () async {
    final core = FakePhoneCore(
      initialAccounts: [
        _sampleAccount(username: '+15550004001', label: 'A', group: '一组'),
        _sampleAccount(username: '+15550004002', label: 'B', group: '二组'),
      ],
    );
    final controller = PhoneController(core: core, history: []);
    await controller.start();

    await controller.updateAccountMeta(
      '+15550004002@sip.example.test',
      label: 'VIP 专线',
      group: '售后组',
    );
    await controller.selectDefaultAccount('+15550004002@sip.example.test');
    expect(controller.defaultAccountKey, '+15550004002@sip.example.test');
    expect(controller.selectedLine.label, 'VIP 专线');
    expect(controller.selectedLine.group, '售后组');

    controller.simulateIncoming(aiTransfer: true);
    expect(controller.call?.ownNumber, '+15550004002');
    expect(controller.call?.transferSource, 'ai');
    expect(controller.call?.transferReason, '客户申请人工售后');

    await controller.answer();
    expect(controller.call?.phase, CallPhase.active);
    await controller.toggleHold();
    expect(controller.call?.held, isTrue);

    await controller.hangup();
    expect(controller.history.first.ownNumber, '+15550004002');
    expect(controller.history.first.transferSource, 'ai');
    expect(controller.history.first.transferReason, '客户申请人工售后');

    await controller.setAccountEnabled('+15550004002@sip.example.test', false);
    controller.appendDigit('9');
    expect(controller.canDial, isFalse);
  });

  test('hangup force-clears call state even if native core throws', () async {
    final core = _FailingHangupPhoneCore(
      initialAccounts: [_sampleAccount(username: '+15550004099')],
    );
    final controller = PhoneController(core: core, history: []);
    await controller.start();

    controller.setNumber('9191');
    await controller.dial();
    expect(controller.call, isNotNull);

    await controller.hangup();
    expect(controller.call, isNull);
    expect(controller.history, isNotEmpty);
    expect(controller.history.first.peer, '9191');
    expect(controller.history.first.outcome, CallOutcome.cancelled);
    expect(controller.callNotice, isNull);
  });

  test('remote 486 rejection records rejected outcome and exposes callNotice', () async {
    final core = FakePhoneCore(
      initialAccounts: [_sampleAccount(username: '+15550004099')],
    );
    final controller = PhoneController(core: core, history: []);
    await controller.start();

    controller.setNumber('9202');
    await controller.dial();
    core.simulateRemoteEnd(code: 486, reason: 'Busy Here');

    expect(controller.call, isNull);
    expect(controller.history.first.outcome, CallOutcome.rejected);
    expect(controller.history.first.endReason, '对方正在通话中或挂断了来电。');
    expect(controller.callNotice?.peer, '9202');
    expect(controller.callNotice?.title, '对方正忙或已拒接');
    expect(controller.callNotice?.isWarning, isTrue);
  });

  test('carrier credit limit Reason maps to failed outcome and friendly credit notice', () async {
    final core = FakePhoneCore(
      initialAccounts: [_sampleAccount(username: '+15550004099')],
    );
    final controller = PhoneController(core: core, history: []);
    await controller.start();

    controller.setNumber('9205');
    await controller.dial();
    core.simulateRemoteEnd(
      code: 403,
      sipReasons: const [
        'Q.850;cause=21',
        'SIP;cause=402;text="CARRIER_CREDIT_LIMIT"',
      ],
    );

    expect(controller.call, isNull);
    expect(controller.history.first.outcome, CallOutcome.failed);
    expect(controller.history.first.endReason, '当前号码余额不足，无法拨打。');
    expect(controller.callNotice?.title, '余额不足');
    expect(controller.callNotice?.isWarning, isFalse);
  });

  test('mid-call ENGINE_MEDIA_FAILED, UPSTREAM_SIP_487, Q.850, and completed elsewhere are handled accurately', () async {
    final core = FakePhoneCore(
      initialAccounts: [_sampleAccount(username: '+15550004099')],
    );
    final controller = PhoneController(core: core, history: []);
    await controller.start();

    // Active call aborted mid-call by ENGINE_MEDIA_FAILED
    controller.setNumber('9201');
    await controller.dial();
    core.simulateConnected();
    core.simulateRemoteEnd(
      code: 200,
      sipReasons: const ['SIP;cause=500;text="ENGINE_MEDIA_FAILED"'],
    );
    expect(controller.history.first.outcome, CallOutcome.failed);
    expect(controller.callNotice?.title, '通话异常中断');

    // Active call aborted mid-call via FreeSWITCH-bridged Q.850 cause=41
    controller.setNumber('9204');
    await controller.dial();
    core.simulateConnected();
    core.simulateRemoteEnd(
      code: 200,
      sipReasons: const ['Q.850;cause=41;text="TEMPORARY_FAILURE"'],
    );
    expect(controller.history.first.outcome, CallOutcome.failed);
    expect(controller.callNotice?.title, '通话异常中断');
    expect(controller.history.first.endReason, contains('媒体连接中断'));

    // Normal mid-call hangup with Q.850 cause=16 must remain completed
    controller.setNumber('9201');
    await controller.dial();
    core.simulateConnected();
    core.simulateRemoteEnd(
      code: 200,
      sipReasons: const ['Q.850;cause=16;text="NORMAL_CLEARING"'],
    );
    expect(controller.history.first.outcome, CallOutcome.completed);
    expect(controller.callNotice, isNull);

    // Outgoing UPSTREAM_SIP_487 without local cancel must be failed, not cancelled
    controller.setNumber('9202');
    await controller.dial();
    core.simulateRemoteEnd(
      code: 487,
      sipReasons: const ['SIP;cause=487;text="UPSTREAM_SIP_487"'],
    );
    expect(controller.history.first.outcome, CallOutcome.failed);
    expect(controller.callNotice?.title, '呼叫被上游中止');

    // LINE_SUSPENDED and Q.850 fallback
    controller.setNumber('9203');
    await controller.dial();
    core.simulateRemoteEnd(
      code: 409,
      sipReasons: const ['SIP;cause=503;text="LINE_SUSPENDED"'],
    );
    expect(controller.history.first.outcome, CallOutcome.failed);
    expect(controller.callNotice?.title, '线路已停用');

    controller.setNumber('9204');
    await controller.dial();
    core.simulateRemoteEnd(
      code: 502,
      sipReasons: const ['Q.850;cause=1;text="UNALLOCATED_NUMBER"'],
    );
    expect(controller.history.first.outcome, CallOutcome.failed);
    expect(controller.callNotice?.title, '空号或号码无效');

    // Incoming call cancelled because answered on another device
    core.simulateIncoming(peer: '10086');
    core.simulateRemoteEnd(
      code: 487,
      sipReasons: const ['SIP;cause=200;text="Call completed elsewhere"'],
    );
    expect(controller.history.first.outcome, CallOutcome.cancelled);
    expect(controller.history.first.endReason, '已在其他设备接听');

    // Format registration errors & localized outcome label
    expect(formatRegistrationError('401 Unauthorized'), '账号认证失败（401），请重新扫码配网');
    expect(formatRegistrationError('408 Request Timeout'), '注册响应超时，正在重试');
    expect(
      formatRegistrationError(
        '503 SSL certificate verification error (PJSIP_TLS_ECERTVERIF)',
      ),
      'TLS 证书校验或握手失败',
    );
    expect(
      formatRegistrationError('503 End of file (PJ_EEOF)'),
      '连接被网络或代理中断，若开启 Clash/VPN 请将本应用或网关域名设为直连',
    );
    expect(
      formatRegistrationError('503 Connection reset by peer'),
      '连接被网络或代理中断，若开启 Clash/VPN 请将本应用或网关域名设为直连',
    );
    expect(
      formatRegistrationError('503 Connection refused'),
      '无法连接 SIP 服务器，请检查网络或代理分流设置',
    );
    expect(
      formatRegistrationError('503 Network is unreachable'),
      '无法连接 SIP 服务器，请检查网络或代理分流设置',
    );
    expect(
      formatRegistrationError('503 Unable to resolve host'),
      '无法连接 SIP 服务器，请检查网络或代理分流设置',
    );
    expect(
      formatRegistrationError('503 Service Unavailable'),
      '网关暂不可用（503），正在重试',
    );
    expect(outcomeLabelFor(CallOutcome.rejected, CallDirection.incoming), '已拒接');
    expect(outcomeLabelFor(CallOutcome.rejected, CallDirection.outgoing), '对方拒接');
  });

  test('importProvisioningBatch tracks added, updated and partial failures', () async {
    final core = FakePhoneCore(
      initialAccounts: [_sampleAccount(username: '+15550005001')],
    );
    final controller = PhoneController(core: core, history: []);
    await controller.start();

    final summary = await controller.importProvisioningBatch(
      [
        'https://prov.example.invalid/t1',
        'https://10.20.30.40/t-tls',
        'https://prov.example.invalid/t1', // duplicate
      ],
      urlFetcher: (url, {bool allowSelfSignedLan = false}) async {
        if (url.contains('t-tls')) {
          throw const FormatException('TLS 证书校验失败；请重试');
        }
        return parseProvisioningPayload('''
{
  "sip_proxy": "<sip:sip.example.test:5061;transport=tls>;lr",
  "accounts": [
    {
      "sip_username": "+15550005001",
      "domain": "sip.example.test",
      "ha1": "0123456789abcdef0123456789abcdef"
    },
    {
      "sip_username": "c_new_5002",
      "number": "+15550005002",
      "domain": "sip.example.test",
      "ha1": "fedcba9876543210fedcba9876543210"
    }
  ]
}
''');
      },
    );

    expect(summary.totalAccounts, 2);
    expect(summary.updatedCount, 1);
    expect(summary.addedCount, 1);
    expect(summary.boundNumbers, ['+15550005001', '+15550005002']);
    expect(summary.tlsFailedUrls, ['https://10.20.30.40/t-tls']);
    expect(summary.failures, hasLength(1));
  });
}

class _FailingHangupPhoneCore extends FakePhoneCore {
  _FailingHangupPhoneCore({super.initialAccounts});

  @override
  Future<void> hangup(String callId) async {
    throw StateError('PJSIP_ESESSIONTERMINATED');
  }
}
