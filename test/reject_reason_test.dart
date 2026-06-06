import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/core/errors.dart';

/// Логика, которая чинит «вечный долбёж» outbox и не теряет сообщения на
/// throttle: permanent-отказы дропаем, транзиентные/незнакомые — повторяем.
void main() {
  group('MaxRejected.isPermanent', () {
    test('постоянные отказы (получатель/чат не найден) → permanent', () {
      expect(
        const MaxRejected('x', 3, reason: 'user.not.found').isPermanent,
        isTrue,
      );
      expect(
        const MaxRejected('x', 3, reason: 'chat.not.found').isPermanent,
        isTrue,
      );
      expect(
        const MaxRejected('x', 3, reason: 'recipient.not.found').isPermanent,
        isTrue,
      );
      expect(
        const MaxRejected('x', 3, reason: 'user.blocked').isPermanent,
        isTrue,
      );
    });

    test('транзиентные и незнакомые коды → НЕ permanent (повтор)', () {
      expect(
        const MaxRejected('x', 3, reason: 'too.many.requests').isPermanent,
        isFalse,
      );
      expect(
        const MaxRejected('x', 3, reason: 'flood.wait').isPermanent,
        isFalse,
      );
      expect(
        const MaxRejected('x', 3, reason: 'something.unknown').isPermanent,
        isFalse,
      );
      expect(const MaxRejected('x', 3).isPermanent, isFalse); // reason == null
    });
  });
}
