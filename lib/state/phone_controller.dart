import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/call_history_store.dart';
import '../core/debug_sip_config.dart';
import '../core/fake_phone_core.dart';
import '../core/phone_core.dart';
import '../core/provisioning.dart';
import '../models/phone_models.dart';
import '../utils/format.dart';

class CallBannerNotice {
  const CallBannerNotice({
    required this.peer,
    required this.title,
    required this.message,
    this.isWarning = false,
  });

  final String peer;
  final String title;
  final String message;
  final bool isWarning;
}

const _demoLine = PhoneLine(
  id: 'demo',
  label: '本地演示分机',
  number: '本地演示 · 不拨真实电话',
  status: LineStatus.ready,
  group: '演示',
);

const _unboundLine = PhoneLine(
  id: 'unbound',
  label: '尚未绑定号码',
  number: '请先扫码绑定通话号码',
  status: LineStatus.offline,
  group: '未绑定',
  enabled: false,
);

class PhoneController extends ChangeNotifier {
  PhoneController({
    PhoneCore? core,
    List<CallRecord>? history,
    this.historyStore,
  })  : _core = core ?? FakePhoneCore(),
        history = history ?? [] {
    _subscriptions = [
      _core.accounts.listen((next) {
        _applyAccounts(next);
        notifyListeners();
      }),
      _core.registration.listen((state) {
        if (!demoMode || _core is FakePhoneCore) {
          registration = state;
          notifyListeners();
        }
      }),
      _core.callEnded.listen((info) {
        if (!demoMode || _core is FakePhoneCore) {
          _pendingEndInfo = info;
        }
      }),
      _core.calls.listen((next) {
        if (!demoMode || _core is FakePhoneCore) {
          _onCallChanged(next);
        }
      }),
      _core.audioRoute.listen((route) {
        if (!demoMode || _core is FakePhoneCore) {
          audioRoute = route;
          final current = call;
          if (current != null) {
            call = current.copyWith(speakerOn: route == AudioRoute.speaker);
          }
          notifyListeners();
        }
      }),
    ];
  }

  final PhoneCore _core;
  final CallHistoryStore? historyStore;
  late final List<StreamSubscription<dynamic>> _subscriptions;

  FakePhoneCore? _demoCore;
  List<StreamSubscription<dynamic>> _demoSubscriptions = const [];

  final List<CoreAccountState> accounts = [];
  final List<CallRecord> history;

  bool demoMode = false;
  String number = '';
  CoreCall? call;
  CoreRegistration registration = CoreRegistration.unregistered;
  AudioRoute audioRoute = AudioRoute.earpiece;
  CallBannerNotice? callNotice;

  CallEndInfo? _pendingEndInfo;
  bool _started = false;

  List<PhoneLine> get lines => demoMode
      ? const [_demoLine]
      : [for (final acc in accounts) acc.toPhoneLine()];

  bool get needsBinding => !demoMode && accounts.isEmpty;

  PhoneLine get selectedLine {
    if (demoMode) return _demoLine;
    if (accounts.isEmpty) return _unboundLine;
    final def = accounts.cast<CoreAccountState?>().firstWhere(
          (a) => a?.isDefault == true,
          orElse: () => accounts.first,
        );
    return def!.toPhoneLine();
  }

  String? get defaultAccountKey {
    if (accounts.isEmpty) return null;
    final def = accounts.cast<CoreAccountState?>().firstWhere(
          (a) => a?.isDefault == true,
          orElse: () => accounts.first,
        );
    return def?.accountKey;
  }

  int get onlineCount =>
      accounts.where((a) => a.registration == CoreRegistration.registered).length;

  bool get canDial =>
      _started &&
      call == null &&
      number.trim().isNotEmpty &&
      selectedLine.canDial &&
      registration == CoreRegistration.registered;

  PhoneCore get _activeCore =>
      (demoMode && _core is! FakePhoneCore) ? _ensureDemoCore() : _core;

  FakePhoneCore _ensureDemoCore() {
    final existing = _demoCore;
    if (existing != null) return existing;
    final demo = FakePhoneCore();
    _demoCore = demo;
    _demoSubscriptions = [
      demo.registration.listen((state) {
        if (demoMode) {
          registration = state;
          notifyListeners();
        }
      }),
      demo.callEnded.listen((info) {
        if (demoMode) _pendingEndInfo = info;
      }),
      demo.calls.listen((next) {
        if (demoMode) _onCallChanged(next);
      }),
      demo.audioRoute.listen((route) {
        if (demoMode) {
          audioRoute = route;
          final current = call;
          if (current != null) {
            call = current.copyWith(speakerOn: route == AudioRoute.speaker);
          }
          notifyListeners();
        }
      }),
    ];
    return demo;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final store = historyStore;
    if (store != null) {
      final saved = await store.load();
      if (saved.isNotEmpty) {
        history
          ..clear()
          ..addAll(saved);
        notifyListeners();
      }
    }

    var loaded = await _core.loadAccounts();
    if (loaded.isEmpty) {
      final seed = buildSeedAccountFromEnv();
      if (seed != null) {
        await _core.upsertAccounts([seed], registerNow: true);
        loaded = await _core.loadAccounts();
      }
    }

    _applyAccounts(loaded);
    if (accounts.isEmpty) {
      demoMode = false;
      registration = CoreRegistration.unregistered;
    } else {
      demoMode = false;
      await _core.register();
    }
    notifyListeners();
  }

  Future<void> setDemoMode(bool enabled) async {
    if (call != null) {
      throw StateError('通话进行中无法切换模式');
    }
    if (!enabled && accounts.isEmpty) {
      throw StateError('请先导入或添加至少一个 SIP 号码');
    }
    demoMode = enabled;
    if (enabled) {
      final core = _activeCore;
      if (_core is! FakePhoneCore) {
        await _core.unregister();
      }
      await core.register();
    } else {
      await _core.register();
      _syncAggregateRegistration();
    }
    notifyListeners();
  }

  Future<ProvisioningImportResult> importProvisioningUrl(
    String rawUrl, {
    String? groupOverride,
    String? labelPrefix,
    String? registrarOverride,
    bool allowSelfSignedLan = false,
  }) async {
    final result = await fetchProvisioningUrl(
      rawUrl,
      allowSelfSignedLan: allowSelfSignedLan,
    );
    final configs = result.toSipAccountConfigs(
      groupOverride: groupOverride,
      labelPrefix: labelPrefix,
      registrarOverride: registrarOverride,
      allowSelfSignedTls: allowSelfSignedLan,
    );
    await upsertSipAccounts(configs);
    return result;
  }

  Future<ProvisioningImportResult> importProvisioningText(
    String rawText, {
    String? groupOverride,
    String? labelPrefix,
    String? registrarOverride,
    bool allowSelfSignedTls = false,
  }) async {
    final result = parseProvisioningPayload(rawText);
    final configs = result.toSipAccountConfigs(
      groupOverride: groupOverride,
      labelPrefix: labelPrefix,
      registrarOverride: registrarOverride,
      allowSelfSignedTls: allowSelfSignedTls,
    );
    await upsertSipAccounts(configs);
    return result;
  }

  Future<BatchProvisioningSummary> importProvisioningBatch(
    List<String> items, {
    String? groupOverride,
    String? labelPrefix,
    String? registrarOverride,
    bool allowSelfSignedLan = false,
    Future<ProvisioningImportResult> Function(
      String url, {
      bool allowSelfSignedLan,
    })?
        urlFetcher,
  }) async {
    final existingKeys = {for (final acc in accounts) acc.accountKey};
    final collected = <String, SipAccountConfig>{};
    final failures = <String>[];
    final tlsFailedUrls = <String>[];
    final failedInputs = <String>[];
    final fetch = urlFetcher ?? fetchProvisioningUrl;

    final seenInputs = <String>{};
    for (var i = 0; i < items.length; i++) {
      final rawItem = items[i].trim();
      if (rawItem.isEmpty || !seenInputs.add(rawItem)) continue;

      final normalizedUrl = unwrapProvisioningUrl(rawItem);
      final isUrl = !normalizedUrl.contains('\n') &&
          !normalizedUrl.contains('\r') &&
          (normalizedUrl.toLowerCase().startsWith('https://') ||
              normalizedUrl.toLowerCase().startsWith('http://'));
      try {
        final result = isUrl
            ? await fetch(
                normalizedUrl,
                allowSelfSignedLan: allowSelfSignedLan,
              )
            : parseProvisioningPayload(rawItem);
        final configs = result.toSipAccountConfigs(
          groupOverride: groupOverride,
          labelPrefix: labelPrefix,
          registrarOverride: registrarOverride,
          allowSelfSignedTls: allowSelfSignedLan,
        );
        for (final cfg in configs) {
          collected[cfg.accountKey] = cfg;
        }
      } on FormatException catch (err) {
        final label = isUrl ? _shortUrlLabel(normalizedUrl, i + 1) : '第 ${i + 1} 项';
        failures.add('$label：${err.message}');
        failedInputs.add(isUrl ? normalizedUrl : rawItem);
        if (isUrl) {
          final uri = Uri.tryParse(normalizedUrl);
          if (uri != null &&
              uri.scheme.toLowerCase() == 'https' &&
              isPrivateLanHost(uri.host) &&
              err.message.contains('TLS')) {
            tlsFailedUrls.add(normalizedUrl);
          }
        }
      } catch (err) {
        final label = isUrl ? _shortUrlLabel(normalizedUrl, i + 1) : '第 ${i + 1} 项';
        failures.add('$label：$err');
        failedInputs.add(isUrl ? normalizedUrl : rawItem);
      }
    }

    final configs = collected.values.toList();
    if (configs.isNotEmpty) {
      await upsertSipAccounts(configs);
    }

    var addedCount = 0;
    var updatedCount = 0;
    final boundNumbers = <String>[];
    for (final cfg in configs) {
      if (existingKeys.contains(cfg.accountKey)) {
        updatedCount++;
      } else {
        addedCount++;
      }
      final display = cfg.phoneNumber.trim().isNotEmpty
          ? cfg.phoneNumber.trim()
          : cfg.username.trim();
      if (display.isNotEmpty) boundNumbers.add(display);
    }

    return BatchProvisioningSummary(
      addedCount: addedCount,
      updatedCount: updatedCount,
      totalAccounts: configs.length,
      boundNumbers: boundNumbers,
      failures: failures,
      tlsFailedUrls: tlsFailedUrls,
      failedInputs: failedInputs,
    );
  }

  static String _shortUrlLabel(String rawUrl, int index) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.host.isEmpty) return '链接 #$index';
    return '${uri.host} (#$index)';
  }

  Future<void> addOrUpdateAccount(SipAccountConfig config) =>
      upsertSipAccounts([config]);

  Future<void> upsertSipAccounts(List<SipAccountConfig> configs) async {
    if (configs.isEmpty) return;
    await _core.upsertAccounts(configs, registerNow: true);
    final refreshed = await _core.loadAccounts();
    _applyAccounts(refreshed);
    demoMode = false;
    _syncAggregateRegistration();
    notifyListeners();
  }

  Future<void> updateAccountMeta(
    String accountKey, {
    String? label,
    String? group,
  }) async {
    await _core.updateAccountMeta(accountKey, label: label, group: group);
    final refreshed = await _core.loadAccounts();
    _applyAccounts(refreshed);
    notifyListeners();
  }

  Future<void> setAccountEnabled(String accountKey, bool enabled) async {
    await _core.setAccountEnabled(accountKey, enabled);
    final refreshed = await _core.loadAccounts();
    _applyAccounts(refreshed);
    _syncAggregateRegistration();
    notifyListeners();
  }

  Future<void> removeAccount(String accountKey) async {
    await _core.removeAccount(accountKey);
    final refreshed = await _core.loadAccounts();
    _applyAccounts(refreshed);
    if (accounts.isEmpty) {
      registration = CoreRegistration.unregistered;
      notifyListeners();
    } else {
      _syncAggregateRegistration();
      notifyListeners();
    }
  }

  Future<void> selectDefaultAccount(String accountKey) async {
    await _core.selectDefaultAccount(accountKey);
    final refreshed = await _core.loadAccounts();
    _applyAccounts(refreshed);
    if (demoMode && accounts.isNotEmpty) {
      demoMode = false;
    }
    notifyListeners();
  }

  Future<void> reconnectAll() async {
    if (demoMode || accounts.isEmpty) return;
    await _core.register();
    notifyListeners();
  }

  void selectLine(PhoneLine line) {
    if (demoMode || line.id == 'demo') return;
    unawaited(selectDefaultAccount(line.id));
  }

  Future<String?> scanQrCode() => _core.scanQrCode();

  Future<List<String>> scanQrCodes() => _core.scanQrCodes();

  void dismissCallNotice() {
    if (callNotice == null) return;
    callNotice = null;
    notifyListeners();
  }

  void appendDigit(String digit) {
    if (call != null || number.length >= 20) return;
    if (callNotice != null) callNotice = null;
    number += digit;
    notifyListeners();
  }

  void backspace() {
    if (number.isEmpty) return;
    number = number.substring(0, number.length - 1);
    notifyListeners();
  }

  void clearNumber() {
    if (number.isEmpty) return;
    number = '';
    notifyListeners();
  }

  void setNumber(String value) {
    number = value;
    notifyListeners();
  }

  Future<void> dial() async {
    if (!canDial) return;
    final target = number.trim();
    number = '';
    callNotice = null;
    notifyListeners();
    try {
      await _activeCore.dial(
        target,
        accountKey: demoMode ? null : defaultAccountKey,
      );
    } catch (error) {
      number = target;
      callNotice = CallBannerNotice(
        peer: target,
        title: '无法发起呼叫',
        message: '$error',
      );
      notifyListeners();
      rethrow;
    }
  }

  void simulateIncoming({bool aiTransfer = false}) {
    final core = _activeCore;
    if (core is FakePhoneCore) {
      core.simulateIncoming(
        peer: aiTransfer ? '13800138000' : '10086',
        ownNumber: demoMode ? '本地演示分机' : selectedLine.number,
        transferSource: aiTransfer ? 'ai' : null,
        transferReason: aiTransfer ? '客户申请人工售后' : null,
      );
    }
  }

  void simulateConnected() {
    final core = _activeCore;
    if (core is FakePhoneCore) core.simulateConnected();
  }

  Future<void> answer() async {
    final current = call;
    if (current == null || !current.isIncoming) return;
    await _activeCore.answer(current.id);
  }

  Future<void> hangup() async {
    final current = call;
    if (current == null) return;
    try {
      await _activeCore.hangup(current.id);
    } catch (_) {
      if (call?.id == current.id) {
        _pendingEndInfo = const CallEndInfo(localHangup: true);
        _onCallChanged(null);
      }
    }
  }

  Future<void> toggleMute() async {
    final current = call;
    if (current == null) return;
    await _activeCore.setMute(!current.muted);
  }

  Future<void> toggleHold() async {
    final current = call;
    if (current == null || !current.isActive) return;
    await _activeCore.setHold(!current.held);
  }

  Future<void> toggleSpeaker() async {
    final current = call;
    if (current == null) return;
    final next = current.speakerOn ? AudioRoute.earpiece : AudioRoute.speaker;
    await _activeCore.setAudioRoute(next);
  }

  Future<void> sendDtmf(String digit) async {
    if (call == null) return;
    await _activeCore.sendDtmf(digit);
  }

  void clearHistory() {
    if (history.isEmpty) return;
    history.clear();
    notifyListeners();
    unawaited(historyStore?.save(history));
  }

  void _applyAccounts(List<CoreAccountState> next) {
    accounts
      ..clear()
      ..addAll(next);
    if (!demoMode) {
      _syncAggregateRegistration();
    }
  }

  void _syncAggregateRegistration() {
    if (accounts.isEmpty) {
      registration = CoreRegistration.unregistered;
      return;
    }
    if (accounts.any((a) => a.registration == CoreRegistration.registered)) {
      registration = CoreRegistration.registered;
    } else if (accounts.any((a) => a.registration == CoreRegistration.registering)) {
      registration = CoreRegistration.registering;
    } else if (accounts.any((a) => a.registration == CoreRegistration.failed)) {
      registration = CoreRegistration.failed;
    } else {
      registration = CoreRegistration.unregistered;
    }
  }

  void _onCallChanged(CoreCall? next) {
    final previous = call;
    call = next;
    if (previous != null && next == null) _record(previous);
    notifyListeners();
  }

  void _record(CoreCall finished) {
    final endInfo = _pendingEndInfo;
    _pendingEndInfo = null;
    final summary = describeCallEnd(finished: finished, info: endInfo);
    if (summary.noticeTitle != null && summary.noticeMessage != null) {
      callNotice = CallBannerNotice(
        peer: finished.peer,
        title: summary.noticeTitle!,
        message: summary.noticeMessage!,
        isWarning: summary.isWarning,
      );
      _triggerCallNoticeHaptic();
    }

    final answeredAt = finished.answeredAt;
    final duration =
        answeredAt == null ? null : DateTime.now().difference(answeredAt);

    history.insert(
      0,
      CallRecord(
        id: finished.id,
        peer: finished.peer,
        direction: finished.direction,
        outcome: summary.outcome,
        startedAt: finished.startedAt,
        lineLabel: finished.lineLabel,
        duration: duration,
        ownNumber: finished.ownNumber.trim().isEmpty ? null : finished.ownNumber,
        transferSource: finished.transferSource,
        transferReason: finished.transferReason,
        endReason: summary.recordReason ?? summary.noticeMessage,
      ),
    );
    if (history.length > 200) history.removeRange(200, history.length);
    unawaited(historyStore?.save(history));
  }

  void _triggerCallNoticeHaptic() {
    try {
      unawaited(HapticFeedback.mediumImpact().catchError((_) {}));
    } catch (_) {
      // Headless unit tests do not initialize ServicesBinding.
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _demoSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_demoCore?.dispose());
    unawaited(_core.dispose());
    super.dispose();
  }
}
