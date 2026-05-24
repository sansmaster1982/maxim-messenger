import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/constants.dart';

class SecureStorage {
  SecureStorage([FlutterSecureStorage? backend])
    : _backend = backend ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  final FlutterSecureStorage _backend;

  Future<String?> readToken() => _backend.read(key: AppMeta.secureTokenKey);
  Future<void> writeToken(String token) =>
      _backend.write(key: AppMeta.secureTokenKey, value: token);
  Future<void> deleteToken() => _backend.delete(key: AppMeta.secureTokenKey);

  Future<int?> readMyUserId() async {
    final v = await _backend.read(key: AppMeta.prefMyUserIdKey);
    if (v == null) return null;
    return int.tryParse(v);
  }

  Future<void> writeMyUserId(int id) =>
      _backend.write(key: AppMeta.prefMyUserIdKey, value: '$id');
  Future<void> deleteMyUserId() =>
      _backend.delete(key: AppMeta.prefMyUserIdKey);

  Future<void> wipe() async {
    await deleteToken();
    await deleteMyUserId();
  }
}
