import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/data/max/max_codec.dart';

void main() {
  test('frame layout: proto, cmd, seq, opcode, length', () {
    final frame = MaxCodec.frame(
      seq: 0x1234,
      opcode: 64,
      payload: {'k': 1},
    );
    // proto = 10
    expect(frame[0], 10);
    // cmd = 0 (запрос)
    expect(frame[1], 0);
    // seq big-endian
    expect(frame[2], 0x12);
    expect(frame[3], 0x34);
    // opcode big-endian
    expect(frame[4], 0);
    expect(frame[5], 64);
    // длина тела = всё после 10-байтового заголовка
    final bodyLen = (frame[6] << 24) |
        (frame[7] << 16) |
        (frame[8] << 8) |
        frame[9];
    expect(bodyLen, frame.length - 10);
  });
}
