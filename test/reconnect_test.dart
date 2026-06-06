import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/data/max/max_client.dart';

void main() {
  test('MaxConnectionState enum values and transitions', () {
    // Sanity: enum имеет ровно четыре уникальных значения.
    expect(MaxConnectionState.values, hasLength(4));
    expect(
      MaxConnectionState.values.toSet().length,
      MaxConnectionState.values.length,
    );

    // Переменная может пройти жизненный цикл соединения.
    MaxConnectionState s = MaxConnectionState.disconnected;
    expect(s, MaxConnectionState.disconnected);
    s = MaxConnectionState.connecting;
    expect(s, MaxConnectionState.connecting);
    s = MaxConnectionState.connected;
    expect(s, MaxConnectionState.connected);
    s = MaxConnectionState.reconnecting;
    expect(s, MaxConnectionState.reconnecting);
  });
}
