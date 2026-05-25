import 'dart:async';

import 'package:logger/logger.dart';

import '../../core/errors.dart';
import '../local/secure_storage.dart';
import '../max/max_client.dart';

enum AuthState { unauthenticated, awaitingSms, awaiting2fa, authenticated }

class AuthRepository {
  AuthRepository({
    required this.client,
    required this.storage,
    Logger? logger,
  }) : _log = logger ?? Logger();

  final MaxClient client;
  final SecureStorage storage;
  final Logger _log;

  String? _verifyToken;
  String? _trackId;

  /// Попытаться восстановить сессию из secure storage. true - вошли.
  Future<bool> tryRestoreSession() async {
    final saved = await storage.readToken();
    if (saved == null) return false;
    try {
      if (!client.isConnected) await client.connect();
      await client.login(saved);
      try {
        final me = await client.currentProfile();
        final id = me['id'];
        if (id is int) await storage.writeMyUserId(id);
      } catch (_) {}
      return true;
    } catch (e) {
      _log.w('tryRestoreSession failed: $e');
      await storage.deleteToken();
      return false;
    }
  }

  Future<void> requestSms(String phone) async {
    _verifyToken = await _withFreshConnection(() => client.startAuthSms(phone));
  }

  /// Гарантирует живое TLS-соединение и выполняет [op]. Если соединение упало
  /// в течение нескольких миллисекунд после connect (race condition при
  /// устаревшем APP_VERSION или сервер DROP'ит INIT) — делает один retry с
  /// небольшой паузой.
  Future<T> _withFreshConnection<T>(Future<T> Function() op) async {
    Object? lastErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!client.isConnected) {
        try {
          await client.connect();
        } catch (e) {
          lastErr = e;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            continue;
          }
          rethrow;
        }
      }
      try {
        return await op();
      } on MaxNotConnected catch (e) {
        lastErr = e;
        // соединение упало между connect() и операцией — попробуем ещё раз
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw lastErr ?? const MaxNotConnected('connection failed');
  }

  /// Возвращает [AuthState.authenticated] если код принят и токен сохранён,
  /// или [AuthState.awaiting2fa] если включён пароль.
  Future<AuthState> submitSmsCode(String code) async {
    final vt = _verifyToken;
    if (vt == null) throw StateError('SMS не запрошен');
    final r = await client.confirmSms(vt, code);
    if (r.authToken != null) {
      await _completeLogin(r.authToken!);
      return AuthState.authenticated;
    }
    _trackId = r.trackId;
    return AuthState.awaiting2fa;
  }

  Future<void> submit2fa(String password) async {
    final t = _trackId;
    if (t == null) throw StateError('2FA-челлендж отсутствует');
    final token = await client.confirm2fa(t, password);
    await _completeLogin(token);
  }

  Future<void> logout() async {
    await storage.wipe();
    await client.close();
  }

  Future<void> _completeLogin(String token) async {
    await storage.writeToken(token);
    await client.login(token);
    try {
      final me = await client.currentProfile();
      final id = me['id'];
      if (id is int) await storage.writeMyUserId(id);
    } catch (e) {
      _log.w('profile load failed: $e');
    }
  }
}
