import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';

/// Saves an exported file using the platform's standard download behavior.
///
/// Desktop writes to the user's Downloads folder. Web hands the file to the
/// browser download manager. Android and iOS use the app-accessible location
/// provided by the platform; those platforms do not expose one universal,
/// writable Downloads directory to applications.
Future<String> saveDownload({
  required String name,
  required Uint8List bytes,
  required String extension,
  required MimeType mimeType,
}) {
  return FileSaver.instance.saveFile(
    name: name,
    bytes: bytes,
    fileExtension: extension,
    mimeType: mimeType,
  );
}
