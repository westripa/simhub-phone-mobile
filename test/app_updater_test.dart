import 'package:flutter_test/flutter_test.dart';
import 'package:phone/core/app_updater.dart';

void main() {
  test('compareSemver compares major, minor, patch and v prefix accurately', () {
    expect(compareSemver('0.2.0', '0.1.0'), greaterThan(0));
    expect(compareSemver('v1.0.0', '0.9.9'), greaterThan(0));
    expect(compareSemver('0.2.0', '0.2.0'), 0);
    expect(compareSemver('0.1.9', '0.2.0'), lessThan(0));
  });

  test('UpdateRelease parses latest.json manifest and GitHub release fallback', () {
    final manifest = UpdateRelease.fromManifestJson({
      'version': '0.2.1',
      'tag': 'v0.2.1',
      'build_number': 201,
      'apk_name': 'SimHub-Phone-v0.2.1-arm64-signed.apk',
      'apk_url': 'https://github.com/westripa/simhub-phone-mobile/releases/download/v0.2.1/SimHub-Phone-v0.2.1-arm64-signed.apk',
      'sha256': 'ABCD1234',
      'size': 2048,
      'notes': 'Fix reconnect',
    });
    expect(manifest, isNotNull);
    expect(manifest!.version, '0.2.1');
    expect(manifest.buildNumber, 201);
    expect(manifest.sha256, 'abcd1234');

    final gh = UpdateRelease.fromGitHubReleaseJson({
      'tag_name': 'v0.3.0',
      'body': 'Release body',
      'assets': [
        {
          'name': 'SHA256SUMS.txt',
          'browser_download_url': 'https://github.com/westripa/simhub-phone-mobile/releases/download/v0.3.0/SHA256SUMS.txt',
        },
        {
          'name': 'SimHub-Phone-v0.3.0-arm64-signed.apk',
          'browser_download_url': 'https://github.com/westripa/simhub-phone-mobile/releases/download/v0.3.0/SimHub-Phone-v0.3.0-arm64-signed.apk',
          'size': 4096,
        },
      ],
    });
    expect(gh, isNotNull);
    expect(gh!.version, '0.3.0');
    expect(gh.apkName, 'SimHub-Phone-v0.3.0-arm64-signed.apk');
  });

  test('AppUpdaterController enforces in-call guard and handles permission_required', () async {
    var installedCalls = 0;
    var installOutcome = 'permission_required';
    final updater = AppUpdaterController(
      versionFetcher: () async => const AppVersionInfo(versionName: '0.2.0', versionCode: 200),
      manifestFetcher: () async => const UpdateRelease(
        version: '0.2.1',
        tag: 'v0.2.1',
        downloadUrl: 'https://github.com/westripa/simhub-phone-mobile/releases/download/v0.2.1/app.apk',
        apkName: 'app.apk',
        buildNumber: 201,
        sha256: 'deadbeef',
      ),
      apkDownloader: (release, onProgress) async {
        onProgress(50, 100);
        onProgress(100, 100);
        return '/tmp/updates/app.apk';
      },
      apkInstaller: (path, sha) async {
        installedCalls++;
        expect(sha, 'deadbeef');
        return installOutcome;
      },
    );

    final found = await updater.checkForUpdates(silent: false);
    expect(found?.version, '0.2.1');
    expect(updater.status, AppUpdateStatus.available);

    // Must refuse while call is active
    final duringCall = await updater.downloadAndInstall(inCall: true);
    expect(duringCall, isFalse);
    expect(updater.deferredForCall, isTrue);
    expect(installedCalls, 0);

    // First install attempt prompts unknown app sources permission
    final needPerm = await updater.downloadAndInstall(inCall: false);
    expect(needPerm, isFalse);
    expect(updater.status, AppUpdateStatus.permissionRequired);
    expect(installedCalls, 1);

    // Retry succeeds cleanly once permission is granted
    installOutcome = 'launched';
    final launched = await updater.downloadAndInstall(inCall: false);
    expect(launched, isTrue);
    expect(updater.status, AppUpdateStatus.available);
    expect(installedCalls, 2);
  });
}
