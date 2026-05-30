import 'dart:typed_data';

/// Чистый Dart-декодер LZ4 block format (без внешних зависимостей —
/// важно для Android, где FFI-библиотеки тянуть не хочется).
///
/// MAX сжимает тело кадра: старший байт поля длины (cof) = коэффициент,
/// размер распакованного = compressedLen * cof. Это формат LZ4 *block*
/// (не frame), поэтому декодим вручную по спецификации:
/// последовательность [token][literals][match].
class Lz4Block {
  /// Распаковать [src] в буфер размера [destSize].
  /// Бросает [FormatException] при выходе за границы (повреждённые данные).
  static Uint8List decompress(Uint8List src, int destSize) {
    final dst = Uint8List(destSize);
    var sIdx = 0;
    var dIdx = 0;
    final sLen = src.length;

    while (sIdx < sLen) {
      final token = src[sIdx++];

      // ── literals ──
      var litLen = token >> 4;
      if (litLen == 15) {
        int b;
        do {
          if (sIdx >= sLen) throw const FormatException('lz4: lit len EOF');
          b = src[sIdx++];
          litLen += b;
        } while (b == 255);
      }

      if (litLen > 0) {
        if (sIdx + litLen > sLen || dIdx + litLen > destSize) {
          throw const FormatException('lz4: literal overflow');
        }
        dst.setRange(dIdx, dIdx + litLen, src, sIdx);
        sIdx += litLen;
        dIdx += litLen;
      }

      // конец блока: последний токен без match
      if (sIdx >= sLen) break;

      // ── match ──
      if (sIdx + 2 > sLen) throw const FormatException('lz4: offset EOF');
      final offset = src[sIdx] | (src[sIdx + 1] << 8); // little-endian
      sIdx += 2;
      if (offset == 0) throw const FormatException('lz4: zero offset');

      var matchLen = token & 0x0F;
      if (matchLen == 15) {
        int b;
        do {
          if (sIdx >= sLen) throw const FormatException('lz4: match len EOF');
          b = src[sIdx++];
          matchLen += b;
        } while (b == 255);
      }
      matchLen += 4; // minmatch

      var matchPos = dIdx - offset;
      if (matchPos < 0) throw const FormatException('lz4: bad match offset');
      if (dIdx + matchLen > destSize) {
        throw const FormatException('lz4: match overflow');
      }
      // побайтно — диапазоны могут перекрываться (LZ4 это допускает)
      for (var i = 0; i < matchLen; i++) {
        dst[dIdx++] = dst[matchPos++];
      }
    }
    return dst;
  }
}
