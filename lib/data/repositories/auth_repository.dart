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
  /// deviceType берём из сохранённого kind — веб-токен требует WEB.
  Future<bool> tryRestoreSession() async {
    final saved = await storage.readToken();
    if (saved == null) return false;
    final kind = await storage.readTokenKind() ?? 'android';
    final deviceType = kind == 'web' ? 'WEB' : 'ANDROID';
    try {
      if (!client.isConnected) await client.connect(deviceType: deviceType);
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

  /// Вход по готовому auth-token (например из web.max.ru). Веб-токены
  /// сервер принимает только при deviceType=WEB — иначе FAIL_WRONG_PASSWORD.
  Future<void> loginWithToken(String token) async {
    if (client.isConnected) {
      await client.close();
    }
    await client.connect(deviceType: 'WEB');
    await client.login(token);
    await storage.writeToken(token);
    await storage.writeTokenKind('web');
    try {
      final me = await client.currentProfile();
      final id = me['id'];
      if (id is int) await storage.writeMyUserId(id);
    } catch (e) {
      _log.w('profile load failed after token login: $e');
    }
  }

  Future<void> requestSms(String phone) async {
    // SMS-флоу — всегда ANDROID. Если до этого было WEB-соединение
    // (вход по токену), закрываем его и поднимаем чистое ANDROID, иначе
    // _deviceType остался бы WEB и сервер обработал бы запрос иначе.
    if (client.isConnected) {
      await client.close();
    }
    _verifyToken = await _withFreshConnection(
      () => client.startAuthSms(phone),
      deviceType: 'ANDROID',
    );
  }

  /// Гарантирует живое TLS-соединение и выполняет [op]. Если соединение упало
  /// в течение нескольких миллисекунд после connect (race condition при
  /// устаревшем APP_VERSION или сервер DROP'ит INIT) — делает один retry с
  /// небольшой паузой.
  Future<T> _withFreshConnection<T>(
    Future<T> Function() op, {
    String deviceType = 'ANDROID',
  }) async {
    Object? lastErr;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!client.isConnected) {
        try {
          await client.connect(deviceType: deviceType);
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
  ///
  /// Verify-токен одноразовый — если запрос отправлен и сервер его
  /// потребил, повтор приведёт к `cmd=3 INVALID_TOKEN`. Поэтому если
  /// соединение мёртво, поднимаем его ОДИН РАЗ (без сетевого запроса),
  /// потом дёргаем confirmSms ровно один раз. Любая ошибка возвращается
  /// наружу — UI попросит запросить новый SMS.
  Future<AuthState> submitSmsCode(String code) async {
    final vt = _verifyToken;
    if (vt == null) throw StateError('SMS не запрошен');
    if (!client.isConnected) {
      try {
        await client.connect(deviceType: 'ANDROID');
      } catch (e) {
        // Если коннект упал ДО отправки confirmSms — verify-token не использован,
        // можно попробовать ещё раз через 500мс.
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await client.connect(deviceType: 'ANDROID');
      }
    }
    final r = await client.confirmSms(vt, code);
    if (r.authToken != null) {
      await _completeLogin(r.authToken!);
      return AuthState.authenticated;
    }
    _trackId = r.trackId;
    return AuthState.awaiting2fa;
  }

  /// После ошибки `cmd=3` (verify-token истёк/использован) UI должен
  /// сбросить ввод и попросить пользователя нажать «Получить SMS заново».
  void resetSmsState() {
    _verifyToken = null;
  }

  Future<void> submit2fa(String password) async {
    final t = _trackId;
    if (t == null) throw StateError('2FA-челлендж отсутствует');
    final token = await _withFreshConnection(
      () => client.confirm2fa(t, password),
    );
    await _completeLogin(token);
  }

  Future<void> logout() async {
    await storage.wipe();
    await client.close();
  }

  Future<void> _completeLogin(String token) async {
    await storage.writeToken(token);
    await storage.writeTokenKind('android');
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
