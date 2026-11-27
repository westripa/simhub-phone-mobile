import 'dart:convert';
import 'dart:io';

import '../models/phone_models.dart';
import 'phone_core.dart';

final RegExp _ha1Pattern = RegExp(r'^[a-fA-F0-9]{32}$');
final RegExp _xmlEntryPattern = RegExp(
  r'<entry\s+[^>]*name="([^"]+)"[^>]*>([\s\S]*?)<\/entry>',
  caseSensitive: false,
);
final RegExp _xmlSectionPattern = RegExp(
  r'<section\s+[^>]*name="([^"]+)"[^>]*>([\s\S]*?)<\/section>',
  caseSensitive: false,
);

class ProvisionedAccountChoice {
  const ProvisionedAccountChoice({
    required this.slot,
    required this.username,
    required this.domain,
    this.authorizationUsername,
    this.phoneNumber,
    this.realm,
    this.ha1,
    this.password,
    this.label,
    this.group,
    this.multiplex = false,
  });

  final int slot;
  final String username;
  final String domain;
  final String? authorizationUsername;
  final String? phoneNumber;
  final String? realm;
  final String? ha1;
  final String? password;
  final String? label;
  final String? group;
  final bool multiplex;
}

class BatchProvisioningSummary {
  const BatchProvisioningSummary({
    required this.addedCount,
    required this.updatedCount,
    required this.totalAccounts,
    this.boundNumbers = const [],
    this.failures = const [],
    this.tlsFailedUrls = const [],
    this.failedInputs = const [],
  });

  final int addedCount;
  final int updatedCount;
  final int totalAccounts;
  final List<String> boundNumbers;
  final List<String> failures;
  final List<String> tlsFailedUrls;
  final List<String> failedInputs;

  bool get hasFailures => failures.isNotEmpty;
}

/// Extracts a list of provisioning URLs when every non-empty line is a URL
/// (supporting optional `linphone-config:` prefixes). Returns null for XML,
/// JSON, or linphonerc INI payloads.
List<String>? extractProvisioningBatchLines(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.startsWith('{') || trimmed.startsWith('<')) {
    return null;
  }
  final lines = const LineSplitter()
      .convert(trimmed)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.isEmpty) return null;

  final urls = <String>[];
  final seen = <String>{};
  for (final line in lines) {
    final normalized = unwrapProvisioningUrl(line);
    final lower = normalized.toLowerCase();
    if (!lower.startsWith('https://') && !lower.startsWith('http://')) {
      return null;
    }
    if (seen.add(normalized)) {
      urls.add(normalized);
    }
  }
  return urls;
}

class ProvisioningImportResult {
  const ProvisioningImportResult({
    required this.accounts,
    this.registrarUri,
    this.transport = 'tls',
    this.srtp = 'mandatory',
    this.registrationExpiresSec = 300,
  });

  final List<ProvisionedAccountChoice> accounts;
  final String? registrarUri;
  final String transport;
  final String srtp;
  final int registrationExpiresSec;

  List<SipAccountConfig> toSipAccountConfigs({
    String? groupOverride,
    String? labelPrefix,
    String? registrarOverride,
    bool allowSelfSignedTls = false,
  }) {
    final chosenRawRegistrar = (registrarOverride?.trim().isNotEmpty == true)
        ? registrarOverride!.trim()
        : (registrarUri ?? '').trim();
    if (chosenRawRegistrar.isEmpty) {
      throw const FormatException('配网内容缺少 SIP 代理/注册服务器地址，请手动补充服务器地址。');
    }
    final normalizedRegistrar = normalizeSipRegistrarUri(
      chosenRawRegistrar,
      transportHint: transport,
    );
    final resolvedTransport = _detectTransport(normalizedRegistrar) ?? transport;
    final cleanPrefix = labelPrefix?.trim() ?? '';
    final cleanGroupOverride = groupOverride?.trim() ?? '';

    return [
      for (var i = 0; i < accounts.length; i++)
        () {
          final acc = accounts[i];
          final derivedLabel = acc.label?.trim().isNotEmpty == true
              ? acc.label!.trim()
              : cleanPrefix.isEmpty
                  ? ''
                  : (accounts.length == 1
                      ? cleanPrefix
                      : '$cleanPrefix #${i + 1}');
          final derivedGroup = acc.group?.trim().isNotEmpty == true
              ? normalizeAccountGroup(acc.group)
              : cleanGroupOverride.isNotEmpty
                  ? normalizeAccountGroup(cleanGroupOverride)
                  : defaultAccountGroup;
          return SipAccountConfig(
            username: acc.username,
            authUsername: acc.authorizationUsername?.trim() ?? '',
            phoneNumber: acc.phoneNumber?.trim() ?? '',
            domain: acc.domain,
            realm: acc.realm?.trim() ?? '',
            registrarUri: normalizedRegistrar,
            transport: resolvedTransport,
            srtp: srtp,
            ha1: acc.ha1,
            password: acc.password,
            registrationExpiresSec: registrationExpiresSec,
            label: derivedLabel,
            group: derivedGroup,
            enabled: true,
            allowSelfSignedTls: allowSelfSignedTls,
            multiplex: acc.multiplex,
          );
        }(),
    ];
  }
}

/// Strips angle brackets and `;lr` from gateway `sip_proxy` strings such as
/// `<sip:host:5061;transport=tls>` and guarantees `;transport=...`.
String normalizeSipRegistrarUri(String raw, {String? transportHint}) {
  var value = raw.trim();
  if (value.startsWith('<')) {
    final closeIdx = value.indexOf('>');
    if (closeIdx > 1) {
      value =
          '${value.substring(1, closeIdx)}${value.substring(closeIdx + 1)}'.trim();
    }
  }
  if (value.isEmpty) return '';
  if (!value.contains(':')) {
    throw const FormatException('SIP 服务器地址格式无效，应为 sip:主机:端口');
  }
  if (!value.toLowerCase().startsWith('sip:') &&
      !value.toLowerCase().startsWith('sips:')) {
    value = 'sip:$value';
  }
  final parts = value.split(';');
  final base = parts.first.trim();
  final params = <String>[];
  String? existingTransport;
  for (final rawParam in parts.skip(1)) {
    final param = rawParam.trim();
    if (param.isEmpty || param.toLowerCase() == 'lr') continue;
    if (param.toLowerCase().startsWith('transport=')) {
      existingTransport = param.substring('transport='.length).trim().toLowerCase();
      continue;
    }
    params.add(param);
  }
  final chosenTransport = existingTransport ??
      (base.toLowerCase().startsWith('sips:') ? 'tls' : null) ??
      _normalizeTransportValue(transportHint) ??
      'tls';
  params.insert(0, 'transport=$chosenTransport');
  return '$base;${params.join(';')}';
}

ProvisioningImportResult parseProvisioningPayload(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('请粘贴配网链接，或 XML / linphonerc / JSON 配网内容。');
  }
  if (trimmed.startsWith('{')) {
    return _parseJsonProvisioning(trimmed);
  }
  if (trimmed.startsWith('<')) {
    return _parseXmlProvisioning(trimmed);
  }
  return _parseLinphoneRc(trimmed);
}

Future<ProvisioningImportResult> fetchProvisioningUrl(
  String rawUrl, {
  bool allowSelfSignedLan = false,
  HttpClient Function()? clientFactory,
}) async {
  final target = _validateProvisioningUri(rawUrl);
  final query = Map<String, String>.from(target.queryParameters);
  query['format'] = 'json';
  final jsonUri = target.replace(queryParameters: query);

  final client = clientFactory != null ? clientFactory() : HttpClient();
  client.connectionTimeout = const Duration(seconds: 10);
  if (allowSelfSignedLan && isPrivateLanHost(jsonUri.host)) {
    client.badCertificateCallback = (X509Certificate _, String host, _) {
      return isPrivateLanHost(host);
    };
  }

  try {
    final request = await client.getUrl(jsonUri).timeout(const Duration(seconds: 10));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const FormatException('配网链接鉴权失败，请确认网关授权。');
    }
    if (response.statusCode == 404 || response.statusCode == 410) {
      throw const FormatException('配网链接无效或已过期，请在网关重新生成。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('拉取配网失败（HTTP ${response.statusCode}）。');
    }
    return parseProvisioningPayload(body);
  } on TlsException {
    throw const FormatException(
      'TLS 证书校验失败；若为内网测试自签证书，请勾选“允许内网自签证书”后重试。',
    );
  } on SocketException catch (error) {
    throw FormatException('无法连接配网地址：${error.message}');
  } on HttpException catch (error) {
    throw FormatException('拉取配网失败：${error.message}');
  } on StateError catch (error) {
    throw FormatException('拉取配网失败：${error.message}');
  } finally {
    client.close(force: true);
  }
}

/// Strips optional `linphone-config:` prefixes from scanned or pasted URLs.
String unwrapProvisioningUrl(String raw) {
  var value = raw.trim();
  final lower = value.toLowerCase();
  if (lower.startsWith('linphone-config://')) {
    value = value.substring('linphone-config://'.length).trim();
  } else if (lower.startsWith('linphone-config:')) {
    value = value.substring('linphone-config:'.length).trim();
  } else {
    return value;
  }
  final innerLower = value.toLowerCase();
  if (!innerLower.startsWith('https://') &&
      !innerLower.startsWith('http://') &&
      !value.contains('://') &&
      value.isNotEmpty) {
    return 'https://$value';
  }
  return value;
}

bool isPrivateLanHost(String host) {
  final clean = host.trim().replaceAll('[', '').replaceAll(']', '');
  final ip = InternetAddress.tryParse(clean);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  if (b[0] == 10) return true;
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
  if (b[0] == 192 && b[1] == 168) return true;
  return false;
}

Uri _validateProvisioningUri(String rawUrl) {
  final trimmed = unwrapProvisioningUrl(rawUrl);
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const FormatException('配网链接格式无效。');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') {
    throw const FormatException('配网链接仅支持 HTTPS 或局域网 HTTP 地址。');
  }
  final hostLower = uri.host.toLowerCase();
  if (hostLower == 'localhost' ||
      hostLower == '127.0.0.1' ||
      hostLower == '::1' ||
      hostLower == '0.0.0.0') {
    throw const FormatException('配网链接不能指向本机回环地址，请使用手机可达的局域网或公网地址。');
  }
  if (scheme == 'http' && !isPrivateLanHost(uri.host)) {
    throw const FormatException('非局域网地址必须使用 HTTPS 配网链接。');
  }
  return uri;
}

ProvisioningImportResult _parseJsonProvisioning(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('配网 JSON 顶层结构必须是对象。');
  }
  final rawAccounts = decoded['accounts'];
  final expiresRaw = decoded['registration_expires_seconds'];
  final expiresSec =
      expiresRaw is num && expiresRaw.toInt() > 0 ? expiresRaw.toInt() : 300;
  final topTransport =
      _normalizeTransportValue(decoded['transport']?.toString()) ?? 'tls';
  final srtp = _normalizeSrtp(decoded['media_encryption']?.toString());
  final topProxy = _cleanText(decoded['sip_proxy']);
  final registrarUri = topProxy != null
      ? normalizeSipRegistrarUri(topProxy, transportHint: topTransport)
      : null;
  final topMultiplex =
      _cleanText(decoded['mode'])?.toLowerCase() == 'device' ||
          decoded['multiplex'] == true;

  final choices = <ProvisionedAccountChoice>[];
  if (rawAccounts is List && rawAccounts.isNotEmpty) {
    for (var i = 0; i < rawAccounts.length; i++) {
      final item = rawAccounts[i];
      if (item is! Map) continue;
      final username = _cleanText(item['sip_username'] ?? item['username']);
      final domain = _cleanText(item['domain'] ?? decoded['domain']);
      if (username == null || domain == null) continue;
      choices.add(
        ProvisionedAccountChoice(
          slot: item['slot'] is num ? (item['slot'] as num).toInt() : i,
          username: username,
          domain: domain,
          authorizationUsername: _cleanText(
            item['authorization_username'] ?? item['auth_username'],
          ),
          phoneNumber: _cleanText(item['number'] ?? item['phone_number']),
          realm: _cleanText(item['realm'] ?? decoded['realm']),
          ha1: _validateOptionalHa1(_cleanText(item['ha1'])),
          password: _nonEmptyRaw(item['password']),
          label: _cleanText(item['label'] ?? decoded['label']),
          group: _cleanText(item['group']),
          multiplex: topMultiplex || item['multiplex'] == true,
        ),
      );
    }
  } else {
    final username = _cleanText(decoded['sip_username'] ?? decoded['username']);
    final domain = _cleanText(decoded['domain']);
    if (username != null && domain != null) {
      choices.add(
        ProvisionedAccountChoice(
          slot: 0,
          username: username,
          domain: domain,
          authorizationUsername: _cleanText(
            decoded['authorization_username'] ?? decoded['auth_username'],
          ),
          phoneNumber: _cleanText(decoded['number'] ?? decoded['phone_number']),
          realm: _cleanText(decoded['realm']),
          ha1: _validateOptionalHa1(_cleanText(decoded['ha1'])),
          password: _nonEmptyRaw(decoded['password']),
          label: _cleanText(decoded['label']),
          group: _cleanText(decoded['group']),
          multiplex: topMultiplex,
        ),
      );
    }
  }

  if (choices.isEmpty) {
    final embeddedXml = _cleanText(decoded['xml']);
    if (embeddedXml != null) {
      final xmlRes = _parseXmlProvisioning(embeddedXml);
      return ProvisioningImportResult(
        accounts: xmlRes.accounts,
        registrarUri: registrarUri ?? xmlRes.registrarUri,
        transport: topTransport,
        srtp: srtp,
        registrationExpiresSec: expiresSec,
      );
    }
    throw const FormatException('配网 JSON 中缺少账号或域名信息。');
  }

  return ProvisioningImportResult(
    accounts: choices,
    registrarUri: registrarUri,
    transport: topTransport,
    srtp: srtp,
    registrationExpiresSec: expiresSec,
  );
}

ProvisioningImportResult _parseXmlProvisioning(String raw) {
  final sections = <String, Map<String, String>>{};
  for (final match in _xmlSectionPattern.allMatches(raw)) {
    final name = match.group(1)!.trim();
    final body = match.group(2)!;
    final entries = <String, String>{};
    for (final entry in _xmlEntryPattern.allMatches(body)) {
      entries[entry.group(1)!.trim()] = _unescapeXml(entry.group(2)!.trim());
    }
    sections[name] = entries;
  }
  return _buildFromSections(sections);
}

ProvisioningImportResult _parseLinphoneRc(String raw) {
  final sections = <String, Map<String, String>>{};
  var current = '';
  for (final rawLine in const LineSplitter().convert(raw)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1).trim();
      sections.putIfAbsent(current, () => {});
      continue;
    }
    final eq = line.indexOf('=');
    if (eq <= 0 || current.isEmpty) continue;
    sections[current]![line.substring(0, eq).trim()] =
        line.substring(eq + 1).trim();
  }
  return _buildFromSections(sections);
}

ProvisioningImportResult _buildFromSections(
  Map<String, Map<String, String>> sections,
) {
  final indices = <int>{};
  for (final key in sections.keys) {
    final match = RegExp(r'^auth_info_(\d+)$').firstMatch(key);
    if (match != null) indices.add(int.parse(match.group(1)!));
  }
  final sorted = indices.toList()..sort();
  final choices = <ProvisionedAccountChoice>[];
  String? firstProxy;
  int expiresSec = 300;

  for (final idx in sorted) {
    final auth = sections['auth_info_$idx'] ?? const {};
    final proxy = sections['proxy_$idx'] ?? const {};
    final username = _cleanText(auth['username']);
    final domain = _cleanText(auth['domain']);
    if (username == null || domain == null) continue;
    firstProxy ??= _cleanText(proxy['reg_proxy']);
    final regExpires = int.tryParse(proxy['reg_expires'] ?? '');
    if (regExpires != null && regExpires > 0) expiresSec = regExpires;

    final identityMatch = RegExp(r'^"([^"]+)"\s*<sip:', caseSensitive: false)
        .firstMatch(proxy['reg_identity'] ?? '');
    final rawDisplay = _cleanText(identityMatch?.group(1));
    final phoneNum =
        (rawDisplay != null && rawDisplay != username) ? rawDisplay : null;

    choices.add(
      ProvisionedAccountChoice(
        slot: idx,
        username: username,
        domain: domain,
        authorizationUsername: _cleanText(auth['userid']),
        phoneNumber: phoneNum,
        realm: _cleanText(auth['realm']),
        ha1: _validateOptionalHa1(_cleanText(auth['ha1'])),
        password: _nonEmptyRaw(auth['passwd']),
      ),
    );
  }

  if (choices.isEmpty) {
    throw const FormatException('未能识别到有效的 SIP 配网账号（auth_info）。');
  }

  final sipSection = sections['sip'] ?? const {};
  final srtp = _normalizeSrtp(sipSection['media_encryption']);
  final normalizedRegistrar =
      firstProxy != null ? normalizeSipRegistrarUri(firstProxy) : null;
  final transport = normalizedRegistrar != null
      ? (_detectTransport(normalizedRegistrar) ?? 'tls')
      : 'tls';

  return ProvisioningImportResult(
    accounts: choices,
    registrarUri: normalizedRegistrar,
    transport: transport,
    srtp: srtp,
    registrationExpiresSec: expiresSec,
  );
}

String? _validateOptionalHa1(String? value) {
  if (value == null) return null;
  if (!_ha1Pattern.hasMatch(value)) {
    throw const FormatException('配网 HA1 摘要格式无效，必须为 32 位十六进制字符。');
  }
  return value.toLowerCase();
}

String? _cleanText(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

String? _nonEmptyRaw(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

String _normalizeSrtp(String? raw) {
  final lower = raw?.trim().toLowerCase() ?? '';
  return switch (lower) {
    'none' || 'disabled' => 'disabled',
    'optional' => 'optional',
    _ => 'mandatory',
  };
}

String? _normalizeTransportValue(String? raw) {
  final lower = raw?.trim().toLowerCase() ?? '';
  if (lower == 'tls' || lower == 'tcp' || lower == 'udp') return lower;
  return null;
}

String? _detectTransport(String uri) {
  final match = RegExp(r';transport=(tls|tcp|udp)', caseSensitive: false)
      .firstMatch(uri);
  return match?.group(1)?.toLowerCase();
}

String _unescapeXml(String input) => input
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#34;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'");
