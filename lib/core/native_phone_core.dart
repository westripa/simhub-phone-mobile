import 'dart:async';

import 'package:flutter/services.dart';

import 'phone_core.dart';

class PhoneCoreException implements Exception {
  const PhoneCoreException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Bridge to the Android/iOS native SIP core.
///
/// Channel contract:
/// - MethodChannel `simhub.phone/core`: loadAccounts, upsertAccounts,
///   updateAccountMeta, setAccountEnabled, removeAccount, selectDefaultAccount,
///   dial, answer, hangup, setMute, setHold, setAudioRoute, sendDtmf,
///   scanQrCode, scanQrCodes.
/// - EventChannel `simhub.phone/events`: accounts, registration, call, audioRoute.
class NativePhoneCore implements PhoneCore {
  NativePhoneCore({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel('simhub.phone/core'),
        _events = eventChannel ?? const EventChannel('simhub.phone/events');

  final MethodChannel _method;
  final EventChannel _events;
  final _registration = StreamController<CoreRegistration>.broadcast();
  final _accounts = StreamController<List<CoreAccountState>>.broadcast();
  final _calls = StreamController<CoreCall?>.broadcast();
  final _callEnded = StreamController<CallEndInfo>.broadcast();
  final _audioRoute = StreamController<AudioRoute>.broadcast();
  StreamSubscription<dynamic>? _eventsSub;

  @override
  Stream<CoreRegistration> get registration => _registration.stream;

  @override
  Stream<List<CoreAccountState>> get accounts => _accounts.stream;

  @override
  Stream<CoreCall?> get calls => _calls.stream;

  @override
  Stream<CallEndInfo> get callEnded => _callEnded.stream;

  @override
  Stream<AudioRoute> get audioRoute => _audioRoute.stream;

  void _ensureListening() {
    _eventsSub ??= _events.receiveBroadcastStream().listen(
          _handleEvent,
          onError: (Object error) {
            _registration.addError(error);
          },
        );
  }

  @override
  Future<void> initialize(SipConfig config) async {
    _ensureListening();
    await _invoke<void>('initialize', {
      'websocket_url': config.websocketUrl,
      'username': config.username,
      'password': config.password,
      'domain': config.domain,
      'registrar_uri': config.registrarUri,
      'null_audio': config.nullAudio,
      'ice_servers': config.iceServers,
    });
  }

  @override
  Future<void> register() => _invoke<void>('register');

  @override
  Future<void> unregister() => _invoke<void>('unregister');

  @override
  Future<List<CoreAccountState>> loadAccounts() async {
    _ensureListening();
    final raw = await _invoke<List<Object?>>('loadAccounts');
    if (raw == null) return const [];
    final list = <CoreAccountState>[];
    for (final item in raw) {
      if (item is Map) list.add(CoreAccountState.fromMap(item));
    }
    _accounts.add(list);
    return list;
  }

  @override
  Future<void> upsertAccounts(
    List<SipAccountConfig> configs, {
    bool registerNow = true,
  }) {
    _ensureListening();
    return _invoke<void>('upsertAccounts', {
      'accounts': [for (final cfg in configs) cfg.toMap()],
      'register_now': registerNow,
    });
  }

  @override
  Future<void> updateAccountMeta(
    String accountKey, {
    String? label,
    String? group,
  }) =>
      _invoke<void>('updateAccountMeta', {
        'account_key': accountKey,
        'label': ?label,
        'group': ?group,
      });

  @override
  Future<void> setAccountEnabled(String accountKey, bool enabled) =>
      _invoke<void>('setAccountEnabled', {
        'account_key': accountKey,
        'enabled': enabled,
      });

  @override
  Future<void> removeAccount(String accountKey) =>
      _invoke<void>('removeAccount', {'account_key': accountKey});

  @override
  Future<void> selectDefaultAccount(String accountKey) =>
      _invoke<void>('selectDefaultAccount', {'account_key': accountKey});

  @override
  Future<void> dial(String number, {String? accountKey}) =>
      _invoke<void>('dial', {
        'number': number,
        if (accountKey != null && accountKey.isNotEmpty) 'account_key': accountKey,
      });

  @override
  Future<void> answer(String callId) =>
      _invoke<void>('answer', {'call_id': callId});

  @override
  Future<void> hangup(String callId) =>
      _invoke<void>('hangup', {'call_id': callId});

  @override
  Future<void> setMute(bool muted) =>
      _invoke<void>('setMute', {'muted': muted});

  @override
  Future<void> setHold(bool held) => _invoke<void>('setHold', {'held': held});

  @override
  Future<void> setAudioRoute(AudioRoute route) =>
      _invoke<void>('setAudioRoute', {'route': route.name});

  @override
  Future<void> sendDtmf(String digit) =>
      _invoke<void>('sendDtmf', {'digit': digit});

  @override
  Future<String?> scanQrCode() => _invoke<String>('scanQrCode');

  @override
  Future<List<String>> scanQrCodes() async {
    final raw = await _invoke<List<Object?>>('scanQrCodes');
    if (raw == null) return const [];
    return [
      for (final item in raw)
        if ('${item ?? ''}'.trim().isNotEmpty) '${item ?? ''}'.trim(),
    ];
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _method.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw PhoneCoreException(error.code, error.message ?? 'native core error');
    } on MissingPluginException {
      throw const PhoneCoreException(
        'NOT_IMPLEMENTED',
        'native phone core is not available',
      );
    }
  }

  void _handleEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'accounts':
        final raw = event['accounts'];
        if (raw is List) {
          final parsed = <CoreAccountState>[];
          for (final item in raw) {
            if (item is Map) parsed.add(CoreAccountState.fromMap(item));
          }
          _accounts.add(parsed);
        }
      case 'registration':
        final state = CoreRegistration.values.firstWhere(
          (value) => value.name == event['state'],
          orElse: () => CoreRegistration.failed,
        );
        _registration.add(state);
      case 'call':
        final value = event['call'];
        if (value is Map) {
          _calls.add(CoreCall.fromMap(value));
        } else {
          final rawCode = event['code'];
          final code = rawCode is int ? rawCode : int.tryParse('${rawCode ?? ''}');
          final rawReasons = event['sip_reasons'];
          final sipReasons = rawReasons is List
              ? [for (final item in rawReasons) '$item']
              : const <String>[];
          _callEnded.add(
            CallEndInfo(
              code: code,
              reason: event['reason']?.toString(),
              sipReasons: sipReasons,
              localHangup: event['local_hangup'] == true,
            ),
          );
          _calls.add(null);
        }
      case 'audioRoute':
        final route = AudioRoute.values.firstWhere(
          (value) => value.name == event['route'],
          orElse: () => AudioRoute.earpiece,
        );
        _audioRoute.add(route);
    }
  }

  @override
  Future<void> dispose() async {
    await _eventsSub?.cancel();
    await _registration.close();
    await _accounts.close();
    await _calls.close();
    await _callEnded.close();
    await _audioRoute.close();
  }
}
