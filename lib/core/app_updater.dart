import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const defaultMobileManifestUrl =
    'https://github.com/westripa/simhub-phone-mobile/releases/latest/download/latest.json';
const defaultMobileGitHubApiUrl =
    'https://api.github.com/repos/westripa/simhub-phone-mobile/releases/latest';
const defaultMobileReleasesPageUrl =
    'https://github.com/westripa/simhub-phone-mobile/releases';

enum AppUpdateStatus {
  idle,
  checking,
  available,
  downloading,
  installing,
  permissionRequired,
  upToDate,
  error,
}

class AppVersionInfo {
  const AppVersionInfo({
    required this.versionName,
    required this.versionCode,
    this.abis = const [],
  });

  final String versionName;
  final int versionCode;
  final List<String> abis;
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.tag,
    required this.downloadUrl,
    required this.apkName,
    this.buildNumber,
    this.notes = '',
    this.pubDate,
    this.sha256,
    this.size,
  });

  final String version;
  final String tag;
  final String downloadUrl;
  final String apkName;
  final int? buildNumber;
  final String notes;
  final String? pubDate;
  final String? sha256;
  final int? size;

  static UpdateRelease? fromManifestJson(Map<String, dynamic> map) {
    final version = (map['version']?.toString() ?? '').trim();
    final url = (map['apk_url']?.toString() ?? '').trim();
    if (version.isEmpty || url.isEmpty) return null;
    final tag = (map['tag']?.toString() ?? 'v$version').trim();
    final apkName = (map['apk_name']?.toString() ?? Uri.parse(url).pathSegments.lastOrNull ?? 'update.apk').trim();
    final rawBuild = map['build_number'];
    final buildNumber = rawBuild is int ? rawBuild : int.tryParse('${rawBuild ?? ''}');
    final rawSize = map['size'];
    final size = rawSize is int ? rawSize : int.tryParse('${rawSize ?? ''}');
    final sha = map['sha256']?.toString().trim().toLowerCase();
    return UpdateRelease(
      version: version,
      tag: tag,
      downloadUrl: url,
      apkName: apkName.isEmpty ? 'SimHub-Phone.apk' : apkName,
      buildNumber: buildNumber,
      notes: (map['notes']?.toString() ?? '').trim(),
      pubDate: map['pub_date']?.toString().trim(),
      sha256: (sha == null || sha.isEmpty) ? null : sha,
      size: size,
    );
  }

  static UpdateRelease? fromGitHubReleaseJson(Map<String, dynamic> map) {
    final tag = (map['tag_name']?.toString() ?? '').trim();
    if (tag.isEmpty) return null;
    final version = tag.startsWith('v') || tag.startsWith('V')
        ? tag.substring(1)
        : tag;
    final assetsRaw = map['assets'];
    if (assetsRaw is! List) return null;
    Map<String, dynamic>? chosen;
    for (final item in assetsRaw) {
      if (item is! Map) continue;
      final name = item['name']?.toString() ?? '';
      if (!name.toLowerCase().endsWith('.apk')) continue;
      final mapItem = Map<String, dynamic>.from(item);
      if (name.contains('arm64') && name.contains('-signed.apk')) {
        chosen = mapItem;
        break;
      }
      chosen ??= mapItem;
    }
    if (chosen == null) return null;
    final url = (chosen['browser_download_url']?.toString() ?? '').trim();
    if (url.isEmpty) return null;
    final apkName = (chosen['name']?.toString() ?? 'SimHub-Phone.apk').trim();
    final rawSize = chosen['size'];
    final size = rawSize is int ? rawSize : int.tryParse('${rawSize ?? ''}');
    return UpdateRelease(
      version: version,
      tag: tag,
      downloadUrl: url,
      apkName: apkName,
      notes: (map['body']?.toString() ?? '').trim(),
      pubDate: map['published_at']?.toString().trim(),
      size: size,
    );
  }
}

List<int> _parseSemverParts(String raw) {
  final cleaned = raw.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first.split('-').first;
  if (cleaned.isEmpty) return const [0, 0, 0];
  return [
    for (final part in cleaned.split('.')) int.tryParse(part.trim()) ?? 0,
  ];
}

int compareSemver(String a, String b) {
  final pa = _parseSemverParts(a);
  final pb = _parseSemverParts(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final va = i < pa.length ? pa[i] : 0;
    final vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return va.compareTo(vb);
  }
  return 0;
}

typedef ManifestFetcher = Future<UpdateRelease?> Function();
typedef AppVersionFetcher = Future<AppVersionInfo> Function();
typedef ApkDownloader = Future<String> Function(
  UpdateRelease release,
  void Function(int received, int? total) onProgress,
);
typedef ApkInstaller = Future<String> Function(String filePath, String? expectedSha256);

class AppUpdaterController extends ChangeNotifier {
  AppUpdaterController({
    this.supported = true,
    this.releasesPageUrl = defaultMobileReleasesPageUrl,
    MethodChannel? methodChannel,
    this._versionFetcher,
    this._manifestFetcher,
    this._apkDownloader,
    this._apkInstaller,
  }) : _method = methodChannel ?? const MethodChannel('simhub.phone/core');

  AppUpdaterController.disabled()
      : supported = false,
        releasesPageUrl = defaultMobileReleasesPageUrl,
        _method = null,
        _versionFetcher = null,
        _manifestFetcher = null,
        _apkDownloader = null,
        _apkInstaller = null;

  final bool supported;
  final String releasesPageUrl;
  final MethodChannel? _method;
  final AppVersionFetcher? _versionFetcher;
  final ManifestFetcher? _manifestFetcher;
  final ApkDownloader? _apkDownloader;
  final ApkInstaller? _apkInstaller;

  AppUpdateStatus status = AppUpdateStatus.idle;
  String currentVersion = '0.2.0';
  int currentBuildNumber = 200;
  UpdateRelease? availableRelease;
  int downloadedBytes = 0;
  int? totalBytes;
  String? downloadedFilePath;
  String? errorMessage;
  bool deferredForCall = false;

  bool get hasUpdate => availableRelease != null;

  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (downloadedBytes / total).clamp(0.0, 1.0);
  }

  Future<AppVersionInfo> _loadCurrentVersion() async {
    if (_versionFetcher != null) {
      return _versionFetcher();
    }
    final raw = await _method?.invokeMethod<Map<Object?, Object?>>('getAppVersion');
    final versionName = (raw?['version_name']?.toString() ?? currentVersion).trim();
    final rawCode = raw?['version_code'];
    final versionCode = rawCode is int ? rawCode : int.tryParse('${rawCode ?? ''}') ?? currentBuildNumber;
    final rawAbis = raw?['abis'];
    final abis = rawAbis is List ? [for (final a in rawAbis) '$a'] : const <String>[];
    return AppVersionInfo(
      versionName: versionName.isEmpty ? '0.2.0' : versionName,
      versionCode: versionCode,
      abis: abis,
    );
  }

  Future<UpdateRelease?> _fetchRemoteRelease() async {
    if (_manifestFetcher != null) {
      return _manifestFetcher();
    }
    final manifestJson = await _httpGetJson(defaultMobileManifestUrl);
    if (manifestJson != null) {
      final parsed = UpdateRelease.fromManifestJson(manifestJson);
      if (parsed != null) return parsed;
    }
    final ghJson = await _httpGetJson(defaultMobileGitHubApiUrl);
    if (ghJson != null) {
      return UpdateRelease.fromGitHubReleaseJson(ghJson);
    }
    return null;
  }

  Future<String> _downloadApk(
    UpdateRelease release,
    void Function(int received, int? total) onProgress,
  ) async {
    if (_apkDownloader != null) {
      return _apkDownloader(release, onProgress);
    }
    final cacheDirPath = await _method?.invokeMethod<String>('getUpdateCacheDir');
    if (cacheDirPath == null || cacheDirPath.isEmpty) {
      throw StateError('无法访问本地更新缓存目录');
    }
    final safeName = release.apkName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final target = File('$cacheDirPath/$safeName');
    final tmp = File('${target.path}.part');
    if (await tmp.exists()) {
      await tmp.delete();
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = Uri.parse(release.downloadUrl);
      if (uri.scheme != 'https') {
        throw StateError('更新下载地址必须使用 HTTPS');
      }
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'SimHub-Phone-Android/$currentVersion');
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
      final total = res.contentLength > 0 ? res.contentLength : release.size;
      var received = 0;
      onProgress(0, total);
      final sink = tmp.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(target.path);
      return target.path;
    } catch (err) {
      if (await tmp.exists()) {
        await tmp.delete().catchError((_) => tmp);
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _installApk(String filePath, String? expectedSha256) async {
    if (_apkInstaller != null) {
      return _apkInstaller(filePath, expectedSha256);
    }
    final result = await _method?.invokeMethod<String>('installApk', {
      'file_path': filePath,
      if (expectedSha256 != null && expectedSha256.isNotEmpty) 'expected_sha256': expectedSha256,
    });
    return result ?? 'launched';
  }

  Future<void> initVersion() async {
    if (!supported) return;
    try {
      final info = await _loadCurrentVersion();
      currentVersion = info.versionName;
      currentBuildNumber = info.versionCode;
      notifyListeners();
    } catch (_) {}
  }

  Future<UpdateRelease?> checkForUpdates({bool silent = false}) async {
    if (!supported) return null;
    if (status == AppUpdateStatus.checking ||
        status == AppUpdateStatus.downloading ||
        status == AppUpdateStatus.installing) {
      return availableRelease;
    }
    status = AppUpdateStatus.checking;
    errorMessage = null;
    deferredForCall = false;
    if (!silent) notifyListeners();

    try {
      final info = await _loadCurrentVersion();
      currentVersion = info.versionName;
      currentBuildNumber = info.versionCode;

      final remote = await _fetchRemoteRelease();
      if (remote == null) {
        availableRelease = null;
        status = silent ? AppUpdateStatus.idle : AppUpdateStatus.upToDate;
        notifyListeners();
        return null;
      }

      final newerSemver = compareSemver(remote.version, currentVersion) > 0;
      final newerBuild = remote.buildNumber != null &&
          compareSemver(remote.version, currentVersion) == 0 &&
          remote.buildNumber! > currentBuildNumber;

      if (newerSemver || newerBuild) {
        availableRelease = remote;
        status = AppUpdateStatus.available;
        errorMessage = null;
        notifyListeners();
        return remote;
      }

      availableRelease = null;
      status = silent ? AppUpdateStatus.idle : AppUpdateStatus.upToDate;
      notifyListeners();
      return null;
    } catch (err) {
      if (silent) {
        status = availableRelease != null ? AppUpdateStatus.available : AppUpdateStatus.idle;
      } else {
        status = AppUpdateStatus.error;
        errorMessage = _formatError(err);
      }
      notifyListeners();
      return null;
    }
  }

  Future<bool> downloadAndInstall({required bool inCall}) async {
    if (!supported) return false;
    final release = availableRelease;
    if (release == null) return false;
    if (inCall) {
      deferredForCall = true;
      errorMessage = '当前正在通话中，请结束通话后再下载或安装更新。';
      notifyListeners();
      return false;
    }
    if (status == AppUpdateStatus.downloading || status == AppUpdateStatus.installing) {
      return false;
    }

    deferredForCall = false;
    errorMessage = null;
    try {
      String path;
      final cachedPath = downloadedFilePath;
      if (cachedPath != null &&
          status == AppUpdateStatus.permissionRequired &&
          File(cachedPath).existsSync()) {
        path = cachedPath;
      } else {
        status = AppUpdateStatus.downloading;
        downloadedBytes = 0;
        totalBytes = release.size;
        notifyListeners();
        path = await _downloadApk(release, (received, total) {
          downloadedBytes = received;
          totalBytes = total ?? totalBytes;
          notifyListeners();
        });
        downloadedFilePath = path;
      }

      status = AppUpdateStatus.installing;
      notifyListeners();

      final outcome = await _installApk(path, release.sha256);
      if (outcome == 'permission_required') {
        status = AppUpdateStatus.permissionRequired;
        errorMessage = '请在系统设置中允许“安装未知应用”，返回后再次点击安装。';
        notifyListeners();
        return false;
      }

      status = AppUpdateStatus.available;
      notifyListeners();
      return true;
    } catch (err) {
      status = AppUpdateStatus.error;
      errorMessage = _formatError(err);
      notifyListeners();
      return false;
    }
  }

  static Future<Map<String, dynamic>?> _httpGetJson(String rawUrl) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse(rawUrl);
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'SimHub-Phone-Updater');
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode == 404) return null;
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      }
      final body = await res.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static String _formatError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('sha-256')) {
      return '安装包 SHA-256 校验失败，请重试下载或前往 GitHub Releases 获取。';
    }
    if (lower.contains('socketexception') ||
        lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('handshake')) {
      return '连接更新服务器失败或超时，请检查网络或代理设置后重试。';
    }
    return '检查或下载更新失败：$text';
  }
}

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
