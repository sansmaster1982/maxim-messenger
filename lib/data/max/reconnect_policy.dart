import 'dart:math';

/// Чистая, тестируемая политика переподключения и ограничения частоты re-auth.
///
/// Главный анти-бан-инвариант: не авторизоваться (LOGIN, op 19) чаще, чем раз
/// в [minAuthInterval]. Раньше при простое-дропе клиент реконнектился каждые
/// ~2с с новым INIT+LOGIN — до ~120 авторизаций в час на одном номере. Антифрод
/// MAX трактует это как автоматический re-auth и банит номер. test5.py
/// безопасен не из-за чего-то особенного, а потому что вообще не реконнектит:
/// LOGIN'ы там редкие, человеческого темпа.
///
/// [authThrottle] жёстко ограничивает частоту LOGIN, [baseBackoff] гасит серии
/// неудачных попыток, [breakerTripped] ловит патологический флаппинг. Логика
/// вынесена сюда без сокетов — её покрывают юнит-тесты.
class ReconnectPolicy {
  ReconnectPolicy({
    this.base = const Duration(seconds: 5),
    this.maxDelay = const Duration(seconds: 60),
    this.minAuthInterval = const Duration(seconds: 30),
    this.breakerWindow = const Duration(minutes: 5),
    this.breakerMaxAttempts = 6,
    this.breakerCooldown = const Duration(minutes: 8),
    Random? random,
  }) : _rng = random ?? Random();

  /// Базовая пауза первой попытки.
  final Duration base;

  /// Потолок паузы.
  final Duration maxDelay;

  /// Минимальный интервал между двумя LOGIN. Ключевой анти-бан-параметр.
  final Duration minAuthInterval;

  /// Окно, в котором считаются попытки для предохранителя.
  final Duration breakerWindow;

  /// Сколько попыток за [breakerWindow] считается флаппингом.
  final int breakerMaxAttempts;

  /// Длинная пауза при срабатывании предохранителя.
  final Duration breakerCooldown;

  final Random _rng;

  /// Экспоненциальный backoff по числу ПОДРЯД неудачных попыток (0 = первая),
  /// без джиттера — детерминированно, для тестов. Ограничен [maxDelay].
  Duration baseBackoff(int attempt) {
    final a = attempt < 0 ? 0 : (attempt > 16 ? 16 : attempt);
    final ms = base.inMilliseconds * (1 << a);
    final capped = ms > maxDelay.inMilliseconds ? maxDelay.inMilliseconds : ms;
    return Duration(milliseconds: capped);
  }

  /// Сколько ещё ждать, чтобы соблюсти [minAuthInterval]. [sinceLastLogin] —
  /// время, прошедшее с последней успешной авторизации. Это и отличает
  /// «честный дроп после долгой стабильной сессии» (логинились давно →
  /// reconnect сразу) от «шторма» (логинились только что → ждём).
  Duration authThrottle(Duration sinceLastLogin) {
    if (sinceLastLogin >= minAuthInterval) return Duration.zero;
    return minAuthInterval - sinceLastLogin;
  }

  /// Сработал ли предохранитель: слишком много попыток за окно.
  bool breakerTripped(int attemptsInWindow) =>
      attemptsInWindow >= breakerMaxAttempts;

  /// Итоговая задержка: максимум из backoff, auth-throttle и (при флаппинге)
  /// cooldown, плюс джиттер 0..base/2. Ограничена [maxDelay].
  Duration nextDelay({
    required int attempt,
    required Duration sinceLastLogin,
    required int attemptsInWindow,
  }) {
    // baseBackoff уже ограничен maxDelay. throttle и cooldown — намеренные
    // более длинные паузы (потолок частоты LOGIN и cooldown флаппинга),
    // поэтому maxDelay их НЕ ограничивает.
    var d = baseBackoff(attempt);
    final throttle = authThrottle(sinceLastLogin);
    if (throttle > d) d = throttle;
    if (breakerTripped(attemptsInWindow) && breakerCooldown > d) {
      d = breakerCooldown;
    }
    final jitterMax = (base.inMilliseconds ~/ 2) + 1;
    return Duration(milliseconds: d.inMilliseconds + _rng.nextInt(jitterMax));
  }
}
