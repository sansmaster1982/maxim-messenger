import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/data/max/reconnect_policy.dart';

void main() {
  group('baseBackoff — экспонента с потолком', () {
    final p = ReconnectPolicy(
      base: Duration(seconds: 5),
      maxDelay: Duration(minutes: 5),
    );
    test('растёт по 2^attempt', () {
      expect(p.baseBackoff(0), const Duration(seconds: 5));
      expect(p.baseBackoff(1), const Duration(seconds: 10));
      expect(p.baseBackoff(2), const Duration(seconds: 20));
      expect(p.baseBackoff(3), const Duration(seconds: 40));
    });
    test('ограничена maxDelay', () {
      expect(p.baseBackoff(20), const Duration(minutes: 5));
      expect(p.baseBackoff(100), const Duration(minutes: 5));
    });
    test('отрицательная попытка трактуется как 0', () {
      expect(p.baseBackoff(-5), const Duration(seconds: 5));
    });
  });

  group('authThrottle — потолок частоты LOGIN (главный анти-бан)', () {
    final p = ReconnectPolicy(minAuthInterval: Duration(seconds: 90));
    test('логинились давно → ждать не нужно', () {
      expect(p.authThrottle(const Duration(seconds: 120)), Duration.zero);
      expect(p.authThrottle(const Duration(seconds: 90)), Duration.zero);
    });
    test('логинились недавно → ждём остаток до 90с', () {
      expect(
        p.authThrottle(const Duration(seconds: 30)),
        const Duration(seconds: 60),
      );
      expect(p.authThrottle(Duration.zero), const Duration(seconds: 90));
    });
  });

  group('breakerTripped — предохранитель флаппинга', () {
    final p = ReconnectPolicy(breakerMaxAttempts: 6);
    test('срабатывает на пороге и выше', () {
      expect(p.breakerTripped(5), isFalse);
      expect(p.breakerTripped(6), isTrue);
      expect(p.breakerTripped(12), isTrue);
    });
  });

  group('nextDelay — итоговая пауза', () {
    test('throttle доминирует, когда логинились только что (гасит шторм)', () {
      final p = ReconnectPolicy(
        base: Duration(seconds: 5),
        minAuthInterval: Duration(seconds: 90),
      );
      // attempt 0 дал бы 5с, но с последнего LOGIN всего 10с → ждём ≥80с.
      final d = p.nextDelay(
        attempt: 0,
        sinceLastLogin: const Duration(seconds: 10),
        attemptsInWindow: 1,
      );
      expect(d.inSeconds, greaterThanOrEqualTo(80));
    });

    test('честный дроп после долгой сессии → быстрый reconnect', () {
      final p = ReconnectPolicy(base: Duration(seconds: 5));
      final d = p.nextDelay(
        attempt: 0,
        sinceLastLogin: const Duration(hours: 1),
        attemptsInWindow: 1,
      );
      expect(d.inMilliseconds, greaterThanOrEqualTo(5000));
      expect(d.inSeconds, lessThanOrEqualTo(8)); // 5с + джиттер < 2.5с
    });

    test('предохранитель → длинный cooldown', () {
      final p = ReconnectPolicy(
        base: Duration(seconds: 5),
        breakerMaxAttempts: 6,
        breakerCooldown: Duration(minutes: 8),
      );
      final d = p.nextDelay(
        attempt: 0,
        sinceLastLogin: const Duration(hours: 1),
        attemptsInWindow: 7,
      );
      expect(d.inMinutes, greaterThanOrEqualTo(8));
    });
  });
}
