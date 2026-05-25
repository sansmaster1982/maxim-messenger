import 'dart:convert';
import 'dart:typed_data';

/// Минимальные парсеры значений msgpack по сырому байту, чтобы
/// добывать поля по имени-ключу когда полная декодировка не сработала.
/// Копия helpers из telega-to-max/max_client.py.
class RawParsers {
  static int? readIntAfterKey(Uint8List data, Uint8List key) {
    final pos = _indexOf(data, key);
    if (pos == -1) return null;
    var p = pos + key.length;
    if (p >= data.length) return null;
    final typ = data[p];
    p += 1;
    if (typ == 0xD2 && p + 4 <= data.length) {
      return ByteData.sublistView(data, p, p + 4).getInt32(0, Endian.big);
    }
    if (typ == 0xD3 && p + 8 <= data.length) {
      return ByteData.sublistView(data, p, p + 8).getInt64(0, Endian.big);
    }
    if (typ <= 0x7F) return typ;
    if (typ >= 0xE0) return typ - 256;
    return null;
  }

  static String? readStrAfterKey(Uint8List data, Uint8List key) {
    final pos = _indexOf(data, key);
    if (pos == -1) return null;
    var p = pos + key.length;
    if (p >= data.length) return null;
    final typ = data[p];
    p += 1;
    int n;
    if (typ >= 0xA0 && typ <= 0xBF) {
      n = typ & 0x1F;
    } else if (typ == 0xD9 && p < data.length) {
      n = data[p];
      p += 1;
    } else if (typ == 0xDA && p + 2 <= data.length) {
      n = ByteData.sublistView(data, p, p + 2).getUint16(0, Endian.big);
      p += 2;
    } else if (typ == 0xDB && p + 4 <= data.length) {
      n = ByteData.sublistView(data, p, p + 4).getUint32(0, Endian.big);
      p += 4;
    } else {
      return null;
    }
    if (p + n > data.length) return null;
    return utf8.decode(data.sublist(p, p + n), allowMalformed: true).trim();
  }

  static String? findLongToken(Uint8List data) {
    const valid =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-+.~=';
    final validSet = <int>{for (final c in valid.codeUnits) c};
    String? best;
    final cur = <int>[];
    void flush() {
      if (cur.length > 100) {
        final t = String.fromCharCodes(cur);
        if (best == null || t.length > best!.length) best = t;
      }
      cur.clear();
    }

    for (final b in data) {
      if (validSet.contains(b)) {
        cur.add(b);
      } else {
        flush();
      }
    }
    flush();
    return best;
  }

  static String? findUuid(Uint8List data) {
    // UUID состоит только из ASCII символов, поэтому fromCharCodes тут безопасен.
    final text = String.fromCharCodes(data);
    final re = RegExp(
      r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
    );
    final m = re.firstMatch(text);
    return m?.group(0);
  }

  static int indexOf(Uint8List haystack, Uint8List needle) => _indexOf(
    haystack,
    needle,
  );

  static int _indexOf(Uint8List haystack, Uint8List needle) {
    if (needle.isEmpty || needle.length > haystack.length) return -1;
    outer:
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
