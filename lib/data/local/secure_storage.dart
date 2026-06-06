import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

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

  /// Тип устройства, под которым выдан токен: 'web' (веб-токен из
  /// web.max.ru) или 'android' (вход по SMS). Нужно чтобы при восстановлении
  /// сессии слать серверу тот же deviceType — иначе токен не примут.
  Future<String?> readTokenKind() =>
      _backend.read(key: AppMeta.tokenKindKey);
  Future<void> writeTokenKind(String kind) =>
      _backend.write(key: AppMeta.tokenKindKey, value: kind);

  /// Вернуть стабильный deviceId, создав его при первом обращении.
  /// Формат — UUID v4 (как в рабочем python-клиенте telega-to-max, сервер
  /// такой принимает). Хранится отдельно от токена и НЕ стирается при
  /// logout: одно физическое устройство = один deviceId на всю жизнь
  /// установки. Это убирает бан-сигнал «новое устройство на каждый запуск».
  Future<String> readOrCreateDeviceId() async {
    final existing = await _backend.read(key: AppMeta.deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4();
    await _backend.write(key: AppMeta.deviceIdKey, value: created);
    return created;
  }

  /// Сброс deviceId — только для явного «отвязать устройство». В обычный
  /// wipe() при logout НЕ входит.
  Future<void> deleteDeviceId() => _backend.delete(key: AppMeta.deviceIdKey);

  Future<void> wipe() async {
    await deleteToken();
    await deleteMyUserId();
    await _backend.delete(key: AppMeta.tokenKindKey);
  }
}
