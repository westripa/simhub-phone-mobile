import 'package:flutter_test/flutter_test.dart';
import 'package:phone/core/provisioning.dart';
import 'package:phone/models/phone_models.dart';

void main() {
  test('normalizeSipRegistrarUri strips angle brackets, lr and adds transport', () {
    expect(
      normalizeSipRegistrarUri('<sip:sip.example.test:5061;transport=tls>;lr'),
      'sip:sip.example.test:5061;transport=tls',
    );
    expect(
      normalizeSipRegistrarUri('sips:sip.example.test:5061;lr'),
      'sips:sip.example.test:5061;transport=tls',
    );
    expect(
      normalizeSipRegistrarUri('10.20.30.40:5060', transportHint: 'tcp'),
      'sip:10.20.30.40:5060;transport=tcp',
    );
  });

  test('parseProvisioningPayload parses JSON single and multi-account with HA1', () {
    const ha1 = '0123456789abcdef0123456789abcdef';
    const jsonPayload = '''
{
  "sip_proxy": "<sip:sip.example.test:5061;transport=tls>;lr",
  "transport": "tls",
  "media_encryption": "mandatory",
  "registration_expires_seconds": 300,
  "accounts": [
    {
      "slot": 0,
      "sip_username": "+15550001001",
      "authorization_username": "+15550001001",
      "domain": "sip.example.test",
      "realm": "sip.example.test",
      "ha1": "$ha1",
      "label": "客服主号",
      "group": "客服组"
    },
    {
      "slot": 1,
      "sip_username": "+15550001002",
      "domain": "sip.example.test",
      "password": "demo-password"
    }
  ]
}
''';

    final parsed = parseProvisioningPayload(jsonPayload);
    expect(parsed.registrarUri, 'sip:sip.example.test:5061;transport=tls');
    expect(parsed.transport, 'tls');
    expect(parsed.srtp, 'mandatory');
    expect(parsed.accounts, hasLength(2));

    final configs = parsed.toSipAccountConfigs(
      groupOverride: '售后组',
      labelPrefix: '备用号',
      allowSelfSignedTls: true,
    );
    expect(configs[0].accountKey, '+15550001001@sip.example.test');
    expect(configs[0].ha1, ha1);
    expect(configs[0].label, '客服主号');
    expect(configs[0].group, '客服组');
    expect(configs[0].allowSelfSignedTls, isTrue);
    expect(configs[1].label, '备用号 #2');
    expect(configs[1].group, '售后组');
    expect(configs[1].password, 'demo-password');
  });

  test('parseProvisioningPayload parses JSON with embedded XML', () {
    const payload = '''
{
  "sip_proxy": "<sip:sip.example.test:5061;transport=tls>;lr",
  "xml": "<config><section name=\\"sip\\"><entry name=\\"media_encryption\\">optional</entry></section><section name=\\"proxy_0\\"><entry name=\\"reg_proxy\\">&lt;sip:sip.example.test:5061;transport=tls&gt;</entry></section><section name=\\"auth_info_0\\"><entry name=\\"username\\">+15550001003</entry><entry name=\\"domain\\">sip.example.test</entry><entry name=\\"ha1\\">fedcba9876543210fedcba9876543210</entry></section></config>"
}
''';

    final parsed = parseProvisioningPayload(payload);
    expect(parsed.accounts, hasLength(1));
    expect(parsed.accounts.single.username, '+15550001003');
    expect(parsed.accounts.single.ha1, 'fedcba9876543210fedcba9876543210');
    expect(parsed.registrarUri, 'sip:sip.example.test:5061;transport=tls');
  });

  test('parseProvisioningPayload parses Linphone XML and linphonerc', () {
    const xml = '''
<config>
  <section name="sip">
    <entry name="media_encryption">mandatory</entry>
  </section>
  <section name="proxy_0">
    <entry name="reg_proxy">&lt;sip:sip.example.test:5061;transport=tls&gt;</entry>
    <entry name="reg_expires">180</entry>
  </section>
  <section name="auth_info_0">
    <entry name="username">+15550002001</entry>
    <entry name="userid">+15550002001</entry>
    <entry name="domain">sip.example.test</entry>
    <entry name="ha1">00112233445566778899aabbccddeeff</entry>
  </section>
</config>
''';
    final xmlRes = parseProvisioningPayload(xml);
    expect(xmlRes.registrationExpiresSec, 180);
    expect(xmlRes.srtp, 'mandatory');
    expect(xmlRes.accounts.single.authorizationUsername, '+15550002001');

    const rc = '''
[sip]
media_encryption=optional

[proxy_0]
reg_proxy=<sip:10.20.30.40:5060;transport=tcp>;lr
reg_expires=120

[auth_info_0]
username=+15550002002
domain=sip.example.test
passwd=secret-pass
''';
    final rcRes = parseProvisioningPayload(rc);
    expect(rcRes.transport, 'tcp');
    expect(rcRes.srtp, 'optional');
    expect(rcRes.registrationExpiresSec, 120);
    expect(rcRes.accounts.single.password, 'secret-pass');
    expect(
      rcRes.toSipAccountConfigs(groupOverride: '').single.group,
      defaultAccountGroup,
    );
  });

  test('parseProvisioningPayload rejects invalid 32-hex HA1', () {
    const badJson = '''
{
  "sip_proxy": "sip:sip.example.test:5061;transport=tls",
  "sip_username": "+15550002003",
  "domain": "sip.example.test",
  "ha1": "not-32-hex"
}
''';
    expect(
      () => parseProvisioningPayload(badJson),
      throwsFormatException,
    );
  });

  test('fetchProvisioningUrl rejects loopback and non-LAN HTTP URLs', () async {
    await expectLater(
      fetchProvisioningUrl('http://127.0.0.1:8080/api/v1/provisioning/t'),
      throwsFormatException,
    );
    await expectLater(
      fetchProvisioningUrl('https://localhost:8443/api/v1/provisioning/t'),
      throwsFormatException,
    );
    await expectLater(
      fetchProvisioningUrl('http://sip.example.test/api/v1/provisioning/t'),
      throwsFormatException,
    );
  });

  test('isPrivateLanHost identifies RFC1918 IPv4 hosts without external network', () {
    expect(isPrivateLanHost('10.20.30.40'), isTrue);
    expect(isPrivateLanHost('172.16.1.2'), isTrue);
    expect(isPrivateLanHost('172.31.255.1'), isTrue);
    expect(isPrivateLanHost('172.32.0.1'), isFalse);
    expect(isPrivateLanHost('8.8.8.8'), isFalse);
    expect(isPrivateLanHost('sip.example.test'), isFalse);
  });

  test('unwrapProvisioningUrl strips optional linphone-config prefix', () {
    expect(
      unwrapProvisioningUrl(
        'linphone-config:https://sip.example.test/api/v1/provisioning/tok',
      ),
      'https://sip.example.test/api/v1/provisioning/tok',
    );
    expect(
      unwrapProvisioningUrl(
        'linphone-config://http://10.20.30.40:8467/api/v1/provisioning/tok',
      ),
      'http://10.20.30.40:8467/api/v1/provisioning/tok',
    );
    expect(
      unwrapProvisioningUrl(
        'linphone-config://sip.example.test/api/v1/provisioning/tok',
      ),
      'https://sip.example.test/api/v1/provisioning/tok',
    );
  });

  test('multi-client provisioning preserves bound phone number separately from SIP id', () {
    const jsonPayload = '''
{
  "sip_proxy": "<sip:sip.example.test:5061;transport=tls>;lr",
  "accounts": [
    {
      "slot": 0,
      "sip_username": "c_abc123def456",
      "authorization_username": "c_abc123def456",
      "number": "+15550001001",
      "label": "美区主力机",
      "domain": "sip.example.test",
      "ha1": "0123456789abcdef0123456789abcdef"
    }
  ]
}
''';
    final configs = parseProvisioningPayload(jsonPayload).toSipAccountConfigs();
    expect(configs, hasLength(1));
    expect(configs.single.accountKey, 'c_abc123def456@sip.example.test');
    expect(configs.single.username, 'c_abc123def456');
    expect(configs.single.phoneNumber, '+15550001001');
    expect(configs.single.label, '美区主力机');
  });

  test('extractProvisioningBatchLines parses deduplicated URLs and rejects payloads', () {
    final urls = extractProvisioningBatchLines('''
      linphone-config:https://sip.example.test/api/v1/provisioning/t1
      http://10.20.30.40:8467/api/v1/provisioning/t2
      https://sip.example.test/api/v1/provisioning/t1
    ''');
    expect(urls, [
      'https://sip.example.test/api/v1/provisioning/t1',
      'http://10.20.30.40:8467/api/v1/provisioning/t2',
    ]);
    expect(extractProvisioningBatchLines('{"domain":"sip.example.test"}'), isNull);
    expect(extractProvisioningBatchLines('<config></config>'), isNull);
    expect(extractProvisioningBatchLines('[auth_info_0]\nusername=+15550001'), isNull);
  });
}
