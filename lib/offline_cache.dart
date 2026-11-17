import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Read snapshots in app-private storage, separated by server and credential.
/// Never stores a credential in a filename or returns another account's data.
class ReadCache {
  ReadCache(this.directory);
  final Future<Directory> Function() directory;
  String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
  Future<File> _file(String scope, String path) async => File(
    '${(await directory()).path}/read-cache/${_digest(scope)}/${_digest(path)}.json',
  );
  Future<dynamic> read(String scope, String path) async {
    try {
      return jsonDecode(await (await _file(scope, path)).readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String scope, String path, dynamic data) async {
    try {
      final file = await _file(scope, path);
      await file.parent.create(recursive: true);
      final temp = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await temp.writeAsString(jsonEncode(data), flush: true);
      await temp.rename(file.path);
    } catch (_) {
      /* Cache failure must not fail an online operation. */
    }
  }
}
