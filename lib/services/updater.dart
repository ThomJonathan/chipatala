import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class Updater {
  static const _repo = 'ThomJonathan/chipatala';

  static Uri get _manifest => Uri.parse(
    'https://github.com/$_repo/releases/latest/download/'
    'version-${Platform.isWindows ? 'windows' : 'android'}.json',
  );

  static int _compareVersions(String left, String right) {
    final leftParts = left.split('.').map(int.parse).toList();
    final rightParts = right.split('.').map(int.parse).toList();
    final length = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var i = 0; i < length; i++) {
      final leftPart = i < leftParts.length ? leftParts[i] : 0;
      final rightPart = i < rightParts.length ? rightParts[i] : 0;
      if (leftPart != rightPart) return leftPart.compareTo(rightPart);
    }
    return 0;
  }

  /// Returns the release manifest when a newer version is available.
  static Future<Map<String, dynamic>?> check() async {
    final response = await http
        .get(_manifest)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;

    final version = decoded['version'];
    final url = decoded['url'];
    final checksum = decoded['sha256'];
    if (version is! String ||
        url is! String ||
        checksum is! String ||
        Uri.tryParse(url)?.hasScheme != true) {
      return null;
    }

    final currentVersion = (await PackageInfo.fromPlatform()).version;
    return _compareVersions(version, currentVersion) > 0 ? decoded : null;
  }

  static Future<void> install(Map<String, dynamic> manifest) async {
    final url = manifest['url'];
    final checksum = manifest['sha256'];
    final version = manifest['version'];
    if (url is! String || checksum is! String || version is! String) {
      throw const FormatException('Invalid update manifest');
    }

    if (Platform.isAndroid) {
      OtaUpdate()
          .execute(
            url,
            destinationFilename: 'tumaini-update.apk',
            sha256checksum: checksum,
          )
          .listen((_) {});
      return;
    }

    final response = await http.get(Uri.parse(url));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Could not download the update');
    }

    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'Tumaini-Investments-Setup-$version.exe',
    );
    await file.writeAsBytes(response.bodyBytes, flush: true);

    final actualChecksum = sha256
        .convert(await file.readAsBytes())
        .toString()
        .toLowerCase();
    if (actualChecksum != checksum.toLowerCase()) {
      await file.delete();
      throw const FormatException('Update checksum mismatch');
    }

    await Process.start('cmd', [
      '/c',
      'start',
      '',
      file.path,
      '/SILENT',
      '/CLOSEAPPLICATIONS',
    ], mode: ProcessStartMode.detached);
    exit(0);
  }
}
