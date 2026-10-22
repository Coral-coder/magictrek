import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// A build published on GitHub Releases, as described by the `update.json` asset that the
/// Android release workflow uploads next to the APK.
class ReleaseInfo {
  const ReleaseInfo({required this.versionName, required this.versionCode, required this.tag, required this.apkUrl, this.notes = ''});
  final String versionName;
  final int versionCode;
  final String tag;
  final String apkUrl;
  final String notes;

  static ReleaseInfo? fromJson(Map<String, dynamic> j) {
    final code = j['versionCode'];
    final apk = j['apk'];
    if (code is! num || apk is! String) return null;
    return ReleaseInfo(
      versionName: (j['versionName'] ?? '').toString(),
      versionCode: code.toInt(),
      tag: (j['tag'] ?? '').toString(),
      apkUrl: apk,
      notes: (j['notes'] ?? '').toString(),
    );
  }

  String get label => versionName.isEmpty ? 'build $versionCode' : '$versionName (build $versionCode)';
}

/// Keeps the Android app current with GitHub Releases, with no store in between.
///
/// Every release carries `update.json` (version name, version code, APK link). The app reads
/// the one behind the stable `releases/latest/download/update.json` link, compares the version
/// code with its own, downloads the APK into its cache and hands it to Android's package
/// installer. Android only installs it over the old build when both are signed with the same
/// key, which is why the release workflow signs with the ANDROID_KEYSTORE_* secrets.
class Updater extends ChangeNotifier {
  Updater._();
  static final shared = Updater._();

  static const repo = 'Coral-coder/magictrek';
  static const manifestUrl = 'https://github.com/$repo/releases/latest/download/update.json';
  static const latestApkUrl = 'https://github.com/$repo/releases/latest/download/MagicTrek.apk';
  static const _channel = MethodChannel('magictrek/updater');

  /// Updates are only self-served on Android; iOS builds come through TestFlight.
  bool get supported => !kIsWeb && Platform.isAndroid;

  String installedVersion = '';
  int installedCode = 0;
  ReleaseInfo? available;
  bool checking = false;
  bool downloading = false;
  double progress = 0;
  String? error;
  /// Download a newer build as soon as it is seen, so installing is one tap.
  bool autoDownload = true;
  /// Set once the APK of [available] is in the cache and ready to install.
  File? downloaded;
  DateTime? _lastCheck;
  static const _recheckEvery = Duration(hours: 1);

  Future<void> _readInstalled() async {
    if (installedCode > 0 || !supported) return;
    try {
      final v = await _channel.invokeMapMethod<String, dynamic>('version');
      installedVersion = (v?['name'] ?? '').toString();
      installedCode = (v?['code'] as num?)?.toInt() ?? 0;
    } on PlatformException {
      // Running without the native side (tests); stay at 0 so nothing is offered.
    } on MissingPluginException {
      // Same.
    }
  }

  /// The automatic check: on launch and whenever the app comes back to the foreground, at
  /// most once an hour. When a newer build exists and [autoDownload] is on, the APK is fetched
  /// right away so the prompt can offer "Install" instead of a download.
  Future<ReleaseInfo?> checkAutomatically() async {
    if (!supported) return null;
    final now = DateTime.now();
    if (_lastCheck != null && now.difference(_lastCheck!) < _recheckEvery) return available;
    _lastCheck = now;
    await _cleanCache();
    final release = await check();
    if (release != null && autoDownload && downloaded == null && !downloading) {
      await download(release);
    }
    return release;
  }

  /// Throws away cached APKs; a fresh one is fetched when needed.
  Future<void> _cleanCache() async {
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (await dir.exists()) await dir.delete(recursive: true);
      downloaded = null;
    } catch (_) {}
  }

  /// Looks up the latest release. Returns the newer build, or null when up to date or offline.
  Future<ReleaseInfo?> check() async {
    if (!supported || checking) return available;
    checking = true;
    error = null;
    notifyListeners();
    try {
      await _readInstalled();
      final body = await _get(Uri.parse(manifestUrl));
      final info = ReleaseInfo.fromJson(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
      available = (info != null && installedCode > 0 && info.versionCode > installedCode) ? info : null;
    } catch (e) {
      error = 'Could not reach GitHub: $e';
      available = null;
    } finally {
      checking = false;
      notifyListeners();
    }
    return available;
  }

  /// Fetches the APK of [release] into the cache. Returns the file, or null on failure.
  Future<File?> download(ReleaseInfo release) async {
    if (downloading) return null;
    downloading = true;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      await dir.create(recursive: true);
      final file = File('${dir.path}/MagicTrek-${release.versionCode}.apk');
      await _download(Uri.parse(release.apkUrl), file);
      downloaded = file;
      return file;
    } catch (e) {
      error = 'Download failed: $e';
      return null;
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  /// Hands the downloaded build to Android's package installer. Returns false when the APK is
  /// signed with a different key than the installed app, in which case Android would refuse
  /// the update and the app has to be uninstalled first; the installer is still opened when
  /// [force] is set.
  Future<bool> install({bool force = false}) async {
    final file = downloaded;
    if (file == null || downloading) return false;
    error = null;
    notifyListeners();
    try {
      final same = await _channel.invokeMethod<bool>('sameSigner', {'path': file.path});
      if (same == false && !force) {
        error = 'This build is signed with a different key than the installed app, so Android will not install it over the old one. Uninstall MagicTrek, then install the new build.';
        return false;
      }
      await _channel.invokeMethod('installApk', {'path': file.path});
      return true;
    } catch (e) {
      error = 'Install failed: $e';
      return false;
    } finally {
      notifyListeners();
    }
  }

  /// Downloads [release] (or the known newer build) if needed, then opens the installer.
  Future<bool> downloadAndInstall({ReleaseInfo? release, bool force = false}) async {
    final r = release ?? available;
    if (r == null) return false;
    if (downloaded == null && await download(r) == null) return false;
    return install(force: force);
  }

  /// Opens the installer for an APK that was already downloaded but refused for its signature.
  Future<bool> installAnyway() => install(force: true);

  Future<List<int>> _get(Uri uri) async {
    final client = HttpClient()..userAgent = 'MagicTrek';
    try {
      final req = await client.getUrl(uri);
      req.followRedirects = true;
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
      return (await res.fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk))).takeBytes();
    } finally {
      client.close();
    }
  }

  Future<void> _download(Uri uri, File into) async {
    final client = HttpClient()..userAgent = 'MagicTrek';
    try {
      final req = await client.getUrl(uri);
      req.followRedirects = true;
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
      final total = res.contentLength;
      var received = 0;
      final sink = into.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            final p = received / total;
            if (p - progress >= 0.01) {
              progress = p;
              notifyListeners();
            }
          }
        }
      } finally {
        await sink.close();
      }
      progress = 1;
      notifyListeners();
    } finally {
      client.close();
    }
  }
}
