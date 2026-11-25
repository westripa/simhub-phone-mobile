import 'dart:async';

import '../models/phone_models.dart';
import 'phone_core.dart';

/// In-memory core used in unit/widget tests and local demo mode.
/// It never opens a socket and never touches a real phone line.
class FakePhoneCore implements PhoneCore {
  FakePhoneCore({List<SipAccountConfig>? initialAccounts}) {
    if (initialAccounts != null && initialAccounts.isNotEmpty) {
      for (var i = 0; i < initialAccounts.length; i++) {
        final cfg = initialAccounts[i];
        _accounts.add(
          CoreAccountState(
            accountKey: cfg.accountKey,
            username: cfg.username.trim(),
            authUsername: cfg.authUsername.trim(),
            phoneNumber: cfg.phoneNumber.trim(),
            domain: cfg.domain.trim(),
            realm: cfg.realm.trim(),
            registrarUri: cfg.registrarUri.trim(),
            transport: cfg.transport.trim().toLowerCase(),
            srtp: cfg.srtp.trim().toLowerCase(),
            label: cfg.label.trim(),
            group: normalizeAccountGroup(cfg.group),
            enabled: cfg.enabled,
            isDefault: i == 0,
            hasCredential: _hasSecret(cfg),
            registration: cfg.enabled
                ? CoreRegistration.registered
                : CoreRegistration.unregistered,
          ),
        );
      }
      _defaultAccountKey = _accounts.first.accountKey;
    }
  }

  final _registration = StreamController<CoreRegistration>.broadcast(sync: true);
  final _accountsController =
      StreamController<List<CoreAccountState>>.broadcast(sync: true);
  final _calls = StreamController<CoreCall?>.broadcast(sync: true);
  final _callEnded = StreamController<CallEndInfo>.broadcast(sync: true);
  final _audioRoute = StreamController<AudioRoute>.broadcast(sync: true);

  final List<CoreAccountState> _accounts = [];
  String? _defaultAccountKey;
  CoreCall? _call;
  bool _disposed = false;
  List<String> queuedBatchQrCodes = const [];

  @override
  Stream<CoreRegistration> get registration => _registration.stream;

  @override
  Stream<List<CoreAccountState>> get accounts => _accountsController.stream;

  @override
  Stream<CoreCall?> get calls => _calls.stream;

  @override
  Stream<CallEndInfo> get callEnded => _callEnded.stream;

  @override
  Stream<AudioRoute> get audioRoute => _audioRoute.stream;

  @override
  Future<void> initialize(SipConfig config) async {
    // Keep the fake deterministic; only verify that initialization happened.
  }

  @override
  Future<void> register() async {
    _emitRegistration(CoreRegistration.registering);
    if (_accounts.isNotEmpty) {
      for (var i = 0; i < _accounts.length; i++) {
        if (_accounts[i].enabled) {
          _accounts[i] = _accounts[i].copyWith(
            registration: CoreRegistration.registered,
            clearReason: true,
          );
        }
      }
      _emitAccounts();
    }
    _emitRegistration(CoreRegistration.registered);
  }

  @override
  Future<void> unregister() async {
    for (var i = 0; i < _accounts.length; i++) {
      _accounts[i] = _accounts[i].copyWith(
        registration: CoreRegistration.unregistered,
      );
    }
    _emitAccounts();
    _emitRegistration(CoreRegistration.unregistered);
  }

  @override
  Future<List<CoreAccountState>> loadAccounts() async => List.unmodifiable(_accounts);

  @override
  Future<void> upsertAccounts(
    List<SipAccountConfig> configs, {
    bool registerNow = true,
  }) async {
    for (final cfg in configs) {
      final key = cfg.accountKey;
      final idx = _accounts.indexWhere((a) => a.accountKey == key);
      if (idx >= 0) {
        final existing = _accounts[idx];
        final unchangedTransport = existing.registrarUri == cfg.registrarUri.trim() &&
            existing.transport == cfg.transport.trim().toLowerCase() &&
            existing.srtp == cfg.srtp.trim().toLowerCase() &&
            existing.enabled == cfg.enabled;
        final nextReg = !cfg.enabled
            ? CoreRegistration.unregistered
            : (unchangedTransport &&
                    existing.registration == CoreRegistration.registered)
                ? CoreRegistration.registered
                : (registerNow
                    ? CoreRegistration.registered
                    : existing.registration);
        _accounts[idx] = existing.copyWith(
          authUsername: cfg.authUsername.trim(),
          phoneNumber: cfg.phoneNumber.trim().isNotEmpty
              ? cfg.phoneNumber.trim()
              : existing.phoneNumber,
          realm: cfg.realm.trim(),
          registrarUri: cfg.registrarUri.trim(),
          transport: cfg.transport.trim().toLowerCase(),
          srtp: cfg.srtp.trim().toLowerCase(),
          label: cfg.label.trim().isNotEmpty ? cfg.label.trim() : existing.label,
          group: normalizeAccountGroup(cfg.group),
          enabled: cfg.enabled,
          hasCredential: existing.hasCredential || _hasSecret(cfg),
          registration: nextReg,
          clearReason: true,
        );
      } else {
        _accounts.add(
          CoreAccountState(
            accountKey: key,
            username: cfg.username.trim(),
            authUsername: cfg.authUsername.trim(),
            phoneNumber: cfg.phoneNumber.trim(),
            domain: cfg.domain.trim(),
            realm: cfg.realm.trim(),
            registrarUri: cfg.registrarUri.trim(),
            transport: cfg.transport.trim().toLowerCase(),
            srtp: cfg.srtp.trim().toLowerCase(),
            label: cfg.label.trim(),
            group: normalizeAccountGroup(cfg.group),
            enabled: cfg.enabled,
            isDefault: _accounts.isEmpty,
            hasCredential: _hasSecret(cfg),
            registration: (registerNow && cfg.enabled)
                ? CoreRegistration.registered
                : CoreRegistration.unregistered,
          ),
        );
      }
    }
    _normalizeDefault();
    _emitAccounts();
    _emitAggregateRegistration();
  }

  @override
  Future<void> updateAccountMeta(
    String accountKey, {
    String? label,
    String? group,
  }) async {
    final idx = _accounts.indexWhere((a) => a.accountKey == accountKey);
    if (idx < 0) return;
    _accounts[idx] = _accounts[idx].copyWith(
      label: label?.trim() ?? _accounts[idx].label,
      group: group != null ? normalizeAccountGroup(group) : _accounts[idx].group,
    );
    _emitAccounts();
  }

  @override
  Future<void> setAccountEnabled(String accountKey, bool enabled) async {
    final idx = _accounts.indexWhere((a) => a.accountKey == accountKey);
    if (idx < 0) return;
    _accounts[idx] = _accounts[idx].copyWith(
      enabled: enabled,
      registration:
          enabled ? CoreRegistration.registered : CoreRegistration.unregistered,
      clearReason: true,
    );
    _emitAccounts();
    _emitAggregateRegistration();
  }

  @override
  Future<void> removeAccount(String accountKey) async {
    _accounts.removeWhere((a) => a.accountKey == accountKey);
    if (_defaultAccountKey == accountKey) {
      _defaultAccountKey = null;
    }
    _normalizeDefault();
    _emitAccounts();
    _emitAggregateRegistration();
  }

  @override
  Future<void> selectDefaultAccount(String accountKey) async {
    if (_accounts.every((a) => a.accountKey != accountKey)) return;
    _defaultAccountKey = accountKey;
    _normalizeDefault();
    _emitAccounts();
  }

  @override
  Future<void> dial(String number, {String? accountKey}) async {
    if (_call != null) throw StateError('a call is already active');
    final targetKey = accountKey ?? _defaultAccountKey;
    final slot = _accounts.cast<CoreAccountState?>().firstWhere(
          (a) => a?.accountKey == targetKey,
          orElse: () => _accounts.isNotEmpty ? _accounts.first : null,
        );
    final ownNumber = slot?.displayNumber ?? '';
    final lineLabel = slot == null
        ? '本地演示分机'
        : (slot.label.isNotEmpty ? slot.label : slot.displayNumber);

    _call = CoreCall(
      id: 'fake-${DateTime.now().microsecondsSinceEpoch}',
      peer: number,
      direction: CallDirection.outgoing,
      phase: CallPhase.dialing,
      lineLabel: lineLabel,
      startedAt: DateTime.now(),
      accountKey: slot?.accountKey ?? '',
      ownNumber: ownNumber,
    );
    _calls.add(_call);
  }

  @override
  Future<void> answer(String callId) async {
    final call = _call;
    if (call == null || call.id != callId || !call.isIncoming) return;
    _call = call.copyWith(phase: CallPhase.active, answeredAt: DateTime.now());
    _calls.add(_call);
  }

  @override
  Future<void> hangup(String callId) async {
    if (_call?.id != callId) return;
    _call = null;
    if (!_disposed) {
      _callEnded.add(const CallEndInfo(localHangup: true));
    }
    _calls.add(null);
  }

  void simulateRemoteEnd({
    int code = 486,
    String? reason,
    List<String> sipReasons = const [],
  }) {
    if (_call == null) return;
    _call = null;
    if (!_disposed) {
      _callEnded.add(
        CallEndInfo(
          code: code,
          reason: reason,
          sipReasons: sipReasons,
          localHangup: false,
        ),
      );
    }
    _calls.add(null);
  }

  @override
  Future<void> setMute(bool muted) async {
    final call = _call;
    if (call == null) return;
    _call = call.copyWith(muted: muted);
    _calls.add(_call);
  }

  @override
  Future<void> setHold(bool held) async {
    final call = _call;
    if (call == null) return;
    _call = call.copyWith(held: held);
    _calls.add(_call);
  }

  @override
  Future<void> setAudioRoute(AudioRoute route) async {
    _audioRoute.add(route);
    final call = _call;
    if (call == null) return;
    _call = call.copyWith(speakerOn: route == AudioRoute.speaker);
    _calls.add(_call);
  }

  @override
  Future<void> sendDtmf(String digit) async {
    // UI-only prototype: DTMF is accepted but not transmitted.
  }

  @override
  Future<String?> scanQrCode() async => null;

  @override
  Future<List<String>> scanQrCodes() async => List.unmodifiable(queuedBatchQrCodes);

  void simulateIncoming({
    String peer = '10086',
    String? ownNumber,
    String? lineId,
    String? transferSource,
    String? transferReason,
  }) {
    if (_call != null) return;
    final slot = _accounts.cast<CoreAccountState?>().firstWhere(
          (a) => a?.isDefault == true,
          orElse: () => _accounts.isNotEmpty ? _accounts.first : null,
        );
    final resolvedOwn = ownNumber ?? slot?.displayNumber ?? '';
    final lineLabel = slot == null
        ? '本地演示分机'
        : (slot.label.isNotEmpty ? slot.label : slot.displayNumber);

    _call = CoreCall(
      id: 'fake-${DateTime.now().microsecondsSinceEpoch}',
      peer: peer,
      direction: CallDirection.incoming,
      phase: CallPhase.incoming,
      lineLabel: lineLabel,
      startedAt: DateTime.now(),
      accountKey: slot?.accountKey ?? '',
      ownNumber: resolvedOwn,
      lineId: lineId,
      transferSource: transferSource,
      transferReason: transferReason,
    );
    _calls.add(_call);
  }

  void simulateConnected() {
    final call = _call;
    if (call == null || call.phase == CallPhase.active) return;
    _call = call.copyWith(phase: CallPhase.active, answeredAt: DateTime.now());
    _calls.add(_call);
  }

  void _normalizeDefault() {
    if (_accounts.isEmpty) {
      _defaultAccountKey = null;
      return;
    }
    if (_defaultAccountKey == null ||
        _accounts.every((a) => a.accountKey != _defaultAccountKey)) {
      _defaultAccountKey = _accounts.first.accountKey;
    }
    for (var i = 0; i < _accounts.length; i++) {
      final isDef = _accounts[i].accountKey == _defaultAccountKey;
      if (_accounts[i].isDefault != isDef) {
        _accounts[i] = _accounts[i].copyWith(isDefault: isDef);
      }
    }
  }

  void _emitAggregateRegistration() {
    if (_accounts.isEmpty) return;
    if (_accounts.any((a) => a.registration == CoreRegistration.registered)) {
      _emitRegistration(CoreRegistration.registered);
    } else if (_accounts.any((a) => a.registration == CoreRegistration.registering)) {
      _emitRegistration(CoreRegistration.registering);
    } else if (_accounts.any((a) => a.registration == CoreRegistration.failed)) {
      _emitRegistration(CoreRegistration.failed);
    } else {
      _emitRegistration(CoreRegistration.unregistered);
    }
  }

  void _emitAccounts() {
    if (!_disposed) _accountsController.add(List.unmodifiable(_accounts));
  }

  void _emitRegistration(CoreRegistration state) {
    if (!_disposed) _registration.add(state);
  }

  bool _hasSecret(SipAccountConfig cfg) =>
      (cfg.ha1?.trim().isNotEmpty == true) || (cfg.password?.isNotEmpty == true);

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _registration.close();
    await _accountsController.close();
    await _calls.close();
    await _callEnded.close();
    await _audioRoute.close();
  }
}
