import 'dart:io';

import 'package:flutter/foundation.dart';

import 'phone_core.dart';

/// Optional compile-time seed switches. Runtime provisioning (QR / URL / text)
/// works with normal APK builds without compile-time secrets.
const useNativeCore = bool.fromEnvironment('PHONE_NATIVE_CORE');
const forceFakeCore = bool.fromEnvironment('PHONE_FORCE_FAKE_CORE');

/// The optional line label passed at build time for seed profiles.
const sipLineNumber = String.fromEnvironment('SIP_NUMBER');

const debugSipConfig = SipConfig(
  websocketUrl: String.fromEnvironment('SIP_WSS_URL'),
  username: String.fromEnvironment('SIP_USERNAME'),
  password: String.fromEnvironment('SIP_PASSWORD'),
  domain: String.fromEnvironment('SIP_DOMAIN'),
  registrarUri: String.fromEnvironment('SIP_REGISTRAR'),
  nullAudio: bool.fromEnvironment('SIP_NULL_AUDIO'),
);

/// True when the build explicitly supplied a complete seed SIP account.
bool get nativeCoreSeedProvided =>
    debugSipConfig.username.isNotEmpty &&
    debugSipConfig.domain.isNotEmpty &&
    (debugSipConfig.registrarUri ?? '').isNotEmpty;

/// Backwards-compatible alias for build-time native flag checks.
bool get nativeCoreEnabled => useNativeCore && nativeCoreSeedProvided;

/// Uses Android's native PJSIP core on real/emulator Android devices, while
/// keeping unit/widget tests deterministic on [FakePhoneCore].
bool shouldUseNativeCore() {
  if (forceFakeCore || kIsWeb) return false;
  if (Platform.environment['FLUTTER_TEST'] == 'true') return false;
  return Platform.isAndroid;
}

/// Converts optional `--dart-define` seed parameters into a single runtime
/// [SipAccountConfig] when the local account store is empty.
SipAccountConfig? buildSeedAccountFromEnv() {
  if (!nativeCoreSeedProvided) return null;
  final registrar = debugSipConfig.registrarUri!.trim();
  final lower = registrar.toLowerCase();
  final transport = lower.contains('transport=tcp')
      ? 'tcp'
      : lower.contains('transport=udp')
          ? 'udp'
          : 'tls';
  return SipAccountConfig(
    username: debugSipConfig.username.trim(),
    domain: debugSipConfig.domain.trim(),
    registrarUri: registrar,
    transport: transport,
    srtp: transport == 'tls' ? 'mandatory' : 'disabled',
    password: debugSipConfig.password,
    label: sipLineNumber.trim(),
    nullAudio: debugSipConfig.nullAudio,
  );
}
