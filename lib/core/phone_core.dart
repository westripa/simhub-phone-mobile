import '../models/phone_models.dart';

enum CoreRegistration { unregistered, registering, registered, failed }

enum AudioRoute { earpiece, speaker, bluetooth }

class SipConfig {
  const SipConfig({
    required this.websocketUrl,
    required this.username,
    required this.password,
    required this.domain,
    this.registrarUri,
    this.nullAudio = false,
    this.iceServers = const [],
  });

  final String websocketUrl;
  final String username;
  final String password;
  final String domain;

  /// Native SIP registrar, e.g. `sip:REGISTRAR_HOST:PORT;transport=tls`.
  final String? registrarUri;

  /// Emulator-only debug switch: use PJSIP's null audio device.
  final bool nullAudio;
  final List<String> iceServers;
}

class SipAccountConfig {
  const SipAccountConfig({
    required this.username,
    this.authUsername = '',
    this.phoneNumber = '',
    required this.domain,
    this.realm = '',
    required this.registrarUri,
    this.transport = 'tls',
    this.srtp = 'mandatory',
    this.ha1,
    this.password,
    this.registrationExpiresSec = 300,
    this.label = '',
    this.group = defaultAccountGroup,
    this.enabled = true,
    this.allowSelfSignedTls = false,
    this.nullAudio = false,
  });

  final String username;
  final String authUsername;
  final String phoneNumber;
  final String domain;
  final String realm;
  final String registrarUri;
  final String transport;
  final String srtp;
  final String? ha1;
  final String? password;
  final int registrationExpiresSec;
  final String label;
  final String group;
  final bool enabled;
  final bool allowSelfSignedTls;
  final bool nullAudio;

  String get accountKey => '${username.trim()}@${domain.trim()}';

  Map<String, Object?> toMap() => {
        'account_key': accountKey,
        'username': username.trim(),
        'auth_username': authUsername.trim(),
        'phone_number': phoneNumber.trim(),
        'domain': domain.trim(),
        'realm': realm.trim(),
        'registrar_uri': registrarUri.trim(),
        'transport': transport.trim().toLowerCase(),
        'srtp': srtp.trim().toLowerCase(),
        if (ha1 != null && ha1!.trim().isNotEmpty) 'ha1': ha1!.trim().toLowerCase(),
        if (password != null && password!.isNotEmpty) 'password': password,
        'registration_expires_sec': registrationExpiresSec,
        'label': label.trim(),
        'group': normalizeAccountGroup(group),
        'enabled': enabled,
        'allow_self_signed_tls': allowSelfSignedTls,
        'null_audio': nullAudio,
      };
}

class CoreAccountState {
  const CoreAccountState({
    required this.accountKey,
    required this.username,
    this.authUsername = '',
    this.phoneNumber = '',
    required this.domain,
    this.realm = '',
    required this.registrarUri,
    this.transport = 'tls',
    this.srtp = 'mandatory',
    this.label = '',
    this.group = defaultAccountGroup,
    this.enabled = true,
    this.isDefault = false,
    this.hasCredential = false,
    this.registration = CoreRegistration.unregistered,
    this.reason,
  });

  final String accountKey;
  final String username;
  final String authUsername;
  final String phoneNumber;
  final String domain;
  final String realm;
  final String registrarUri;
  final String transport;
  final String srtp;
  final String label;
  final String group;
  final bool enabled;
  final bool isDefault;
  final bool hasCredential;
  final CoreRegistration registration;
  final String? reason;

  String get displayNumber =>
      phoneNumber.trim().isNotEmpty ? phoneNumber.trim() : username;

  PhoneLine toPhoneLine() {
    final status = switch (registration) {
      CoreRegistration.registered => LineStatus.ready,
      CoreRegistration.registering => LineStatus.connecting,
      CoreRegistration.unregistered || CoreRegistration.failed => LineStatus.offline,
    };
    final shownNumber = displayNumber;
    return PhoneLine(
      id: accountKey,
      label: label.trim().isNotEmpty ? label.trim() : shownNumber,
      number: shownNumber,
      status: status,
      group: normalizeAccountGroup(group),
      domain: domain,
      enabled: enabled,
      reason: reason,
    );
  }

  CoreAccountState copyWith({
    String? accountKey,
    String? username,
    String? authUsername,
    String? phoneNumber,
    String? domain,
    String? realm,
    String? registrarUri,
    String? transport,
    String? srtp,
    String? label,
    String? group,
    bool? enabled,
    bool? isDefault,
    bool? hasCredential,
    CoreRegistration? registration,
    String? reason,
    bool clearReason = false,
  }) {
    return CoreAccountState(
      accountKey: accountKey ?? this.accountKey,
      username: username ?? this.username,
      authUsername: authUsername ?? this.authUsername,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      domain: domain ?? this.domain,
      realm: realm ?? this.realm,
      registrarUri: registrarUri ?? this.registrarUri,
      transport: transport ?? this.transport,
      srtp: srtp ?? this.srtp,
      label: label ?? this.label,
      group: group ?? this.group,
      enabled: enabled ?? this.enabled,
      isDefault: isDefault ?? this.isDefault,
      hasCredential: hasCredential ?? this.hasCredential,
      registration: registration ?? this.registration,
      reason: clearReason ? null : (reason ?? this.reason),
    );
  }

  factory CoreAccountState.fromMap(Map<Object?, Object?> map) {
    final reg = CoreRegistration.values.firstWhere(
      (value) => value.name == map['registration'],
      orElse: () => CoreRegistration.unregistered,
    );
    final username = '${map['username'] ?? ''}'.trim();
    final domain = '${map['domain'] ?? ''}'.trim();
    final rawKey = '${map['account_key'] ?? ''}'.trim();
    final rawReason = '${map['reason'] ?? ''}'.trim();
    return CoreAccountState(
      accountKey: rawKey.isNotEmpty ? rawKey : '$username@$domain',
      username: username,
      authUsername: '${map['auth_username'] ?? ''}'.trim(),
      phoneNumber: '${map['phone_number'] ?? ''}'.trim(),
      domain: domain,
      realm: '${map['realm'] ?? ''}'.trim(),
      registrarUri: '${map['registrar_uri'] ?? ''}'.trim(),
      transport: '${map['transport'] ?? 'tls'}'.trim().toLowerCase(),
      srtp: '${map['srtp'] ?? 'mandatory'}'.trim().toLowerCase(),
      label: '${map['label'] ?? ''}'.trim(),
      group: normalizeAccountGroup(map['group']?.toString()),
      enabled: map['enabled'] != false,
      isDefault: map['is_default'] == true,
      hasCredential: map['has_credential'] == true,
      registration: reg,
      reason: rawReason.isEmpty ? null : rawReason,
    );
  }
}

class CoreCall {
  const CoreCall({
    required this.id,
    required this.peer,
    required this.direction,
    required this.phase,
    required this.lineLabel,
    required this.startedAt,
    this.answeredAt,
    this.muted = false,
    this.speakerOn = false,
    this.accountKey = '',
    this.ownNumber = '',
    this.held = false,
    this.lineId,
    this.transferSource,
    this.transferReason,
    this.gatewayCallId,
  });

  final String id;
  final String peer;
  final CallDirection direction;
  final CallPhase phase;
  final String lineLabel;
  final DateTime startedAt;
  final DateTime? answeredAt;
  final bool muted;
  final bool speakerOn;
  final String accountKey;
  final String ownNumber;
  final bool held;
  final String? lineId;
  final String? transferSource;
  final String? transferReason;
  final String? gatewayCallId;

  bool get isIncoming => direction == CallDirection.incoming;
  bool get isActive => phase == CallPhase.active;

  CoreCall copyWith({
    String? id,
    String? peer,
    CallDirection? direction,
    CallPhase? phase,
    String? lineLabel,
    DateTime? startedAt,
    DateTime? answeredAt,
    bool? muted,
    bool? speakerOn,
    String? accountKey,
    String? ownNumber,
    bool? held,
    String? lineId,
    String? transferSource,
    String? transferReason,
    String? gatewayCallId,
  }) {
    return CoreCall(
      id: id ?? this.id,
      peer: peer ?? this.peer,
      direction: direction ?? this.direction,
      phase: phase ?? this.phase,
      lineLabel: lineLabel ?? this.lineLabel,
      startedAt: startedAt ?? this.startedAt,
      answeredAt: answeredAt ?? this.answeredAt,
      muted: muted ?? this.muted,
      speakerOn: speakerOn ?? this.speakerOn,
      accountKey: accountKey ?? this.accountKey,
      ownNumber: ownNumber ?? this.ownNumber,
      held: held ?? this.held,
      lineId: lineId ?? this.lineId,
      transferSource: transferSource ?? this.transferSource,
      transferReason: transferReason ?? this.transferReason,
      gatewayCallId: gatewayCallId ?? this.gatewayCallId,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'peer': peer,
        'direction': direction.name,
        'phase': phase.name,
        'line_label': lineLabel,
        'started_at': startedAt.toIso8601String(),
        'answered_at': answeredAt?.toIso8601String(),
        'muted': muted,
        'speaker_on': speakerOn,
        'account_key': accountKey,
        'own_number': ownNumber,
        'held': held,
        if (lineId != null && lineId!.isNotEmpty) 'line_id': lineId,
        if (transferSource != null && transferSource!.isNotEmpty)
          'transfer_source': transferSource,
        if (transferReason != null && transferReason!.isNotEmpty)
          'transfer_reason': transferReason,
        if (gatewayCallId != null && gatewayCallId!.isNotEmpty)
          'gateway_call_id': gatewayCallId,
      };

  static CoreCall fromMap(Map<Object?, Object?> map) {
    final direction = CallDirection.values.firstWhere(
      (value) => value.name == map['direction'],
      orElse: () => CallDirection.outgoing,
    );
    final phase = CallPhase.values.firstWhere(
      (value) => value.name == map['phase'],
      orElse: () => CallPhase.dialing,
    );
    final startedAt =
        DateTime.tryParse('${map['started_at'] ?? ''}')?.toLocal() ?? DateTime.now();
    final answeredAt =
        DateTime.tryParse('${map['answered_at'] ?? ''}')?.toLocal();
    return CoreCall(
      id: '${map['id'] ?? ''}',
      peer: '${map['peer'] ?? ''}',
      direction: direction,
      phase: phase,
      lineLabel: '${map['line_label'] ?? ''}',
      startedAt: startedAt,
      answeredAt: answeredAt,
      muted: map['muted'] == true,
      speakerOn: map['speaker_on'] == true,
      accountKey: '${map['account_key'] ?? ''}',
      ownNumber: '${map['own_number'] ?? ''}',
      held: map['held'] == true,
      lineId: _optString(map['line_id']),
      transferSource: _optString(map['transfer_source']),
      transferReason: _optString(map['transfer_reason']),
      gatewayCallId: _optString(map['gateway_call_id']),
    );
  }

  static String? _optString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

class CallEndInfo {
  const CallEndInfo({
    this.code,
    this.reason,
    this.sipReasons = const [],
    this.localHangup = false,
  });

  final int? code;
  final String? reason;
  final List<String> sipReasons;
  final bool localHangup;
}

/// The native side owns SIP, media and call state. Flutter only consumes this
/// interface so the PJSIP/WebRTC implementation can be replaced later without
/// touching the UI.
abstract class PhoneCore {
  Stream<CoreRegistration> get registration;
  Stream<List<CoreAccountState>> get accounts;
  Stream<CoreCall?> get calls;
  Stream<CallEndInfo> get callEnded;
  Stream<AudioRoute> get audioRoute;

  Future<void> initialize(SipConfig config);
  Future<void> register();
  Future<void> unregister();

  Future<List<CoreAccountState>> loadAccounts();
  Future<void> upsertAccounts(
    List<SipAccountConfig> configs, {
    bool registerNow = true,
  });
  Future<void> updateAccountMeta(
    String accountKey, {
    String? label,
    String? group,
  });
  Future<void> setAccountEnabled(String accountKey, bool enabled);
  Future<void> removeAccount(String accountKey);
  Future<void> selectDefaultAccount(String accountKey);

  Future<void> dial(String number, {String? accountKey});
  Future<void> answer(String callId);
  Future<void> hangup(String callId);
  Future<void> setMute(bool muted);
  Future<void> setHold(bool held);
  Future<void> setAudioRoute(AudioRoute route);
  Future<void> sendDtmf(String digit);
  Future<String?> scanQrCode();
  Future<List<String>> scanQrCodes();
  Future<void> dispose();
}
