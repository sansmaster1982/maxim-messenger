import 'dart:typed_data';

import 'package:msgpack_dart/msgpack_dart.dart' as mp;

import '../../core/constants.dart';

/// Кадр MAX-протокола:
///   [0]   PROTO_VER
///   [1]   cmd
///   [2-3] seq (big-endian, 16 бит)
///   [4-5] opcode (big-endian, 16 бит)
///   [6-9] длина тела (3 младших байта, старший игнорируется)
class MaxCodec {
  static Uint8List frame({
    required int seq,
    required int opcode,
    required Map<String, Object?> payload,
  }) {
    final body = mp.serialize(payload);
    final header = Uint8List(10);
    header[0] = MaxProto.protoVersion;
    header[1] = 0;
    header[2] = (seq >> 8) & 0xFF;
    header[3] = seq & 0xFF;
    header[4] = (opcode >> 8) & 0xFF;
    header[5] = opcode & 0xFF;
    final len = body.length;
    header[6] = (len >> 24) & 0xFF;
    header[7] = (len >> 16) & 0xFF;
    header[8] = (len >> 8) & 0xFF;
    header[9] = len & 0xFF;
    final out = BytesBuilder(copy: false)
      ..add(header)
      ..add(body);
    return out.toBytes();
  }

  /// Распаковка может потребовать снять до 4 байт padding'а - копия
  /// эвристики из Python-клиента.
  static Object? tryUnpack(Uint8List data) {
    if (data.isEmpty) return null;
    for (final offset in const [0, 1, 2, 3, 4]) {
      if (offset >= data.length) break;
      try {
        return mp.deserialize(data.sublist(offset));
      } catch (_) {
        // следующая попытка
      }
    }
    return null;
  }
}

class MaxFrame {
  final int cmd;
  final int seq;
  final int opcode;
  final Uint8List body;
  final Object? decoded;

  const MaxFrame({
    required this.cmd,
    required this.seq,
    required this.opcode,
    required this.body,
    required this.decoded,
  });
}
