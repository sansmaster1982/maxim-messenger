import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/data/max/lz4_block.dart';

void main() {
  test('LZ4 block decompress matches reference vector', () {
    // Вектор сгенерирован python lz4.block.compress(store_size=False)
    // из строки 'Привет, это тест LZ4 распаковки! ' * 20.
    const compHex =
        'ff29d09fd180d0b8d0b2d0b5d1822c20d18dd182d0be20d182d0b5d181d18220'
        '4c5a3420d180d0b0d181d0bfd0b0d0bad0bed0b2d0bad0b821203800ffffffff'
        '1450bad0b82120';
    final comp = Uint8List.fromList([
      for (var i = 0; i < compHex.length; i += 2)
        int.parse(compHex.substring(i, i + 2), radix: 16),
    ]);
    final expected = utf8.encode('Привет, это тест LZ4 распаковки! ' * 20);

    final out = Lz4Block.decompress(comp, expected.length);

    expect(out.length, expected.length);
    expect(out, equals(expected));
    expect(utf8.decode(out).startsWith('Привет, это тест'), isTrue);
  });
}
