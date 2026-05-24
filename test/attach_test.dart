import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/data/max/models/attach.dart';

void main() {
  group('MaxAttach', () {
    test('roundtrip server payload preserves type token size', () {
      final a = MaxAttach(
        type: MaxAttachType.photo,
        status: MaxAttachStatus.uploaded,
        token: 'abc',
        size: 1024,
        width: 320,
        height: 240,
      );
      final payload = a.toServerPayload();
      expect(payload['_type'], 'PHOTO');
      expect(payload['token'], 'abc');
      expect(payload['size'], 1024);
      expect(payload['width'], 320);
      expect(payload['height'], 240);
    });

    test('fromServer recognises type and token aliases', () {
      final a = MaxAttach.fromServer({
        '_type': 'VIDEO',
        'token': 'tok',
        'fileId': 42,
        'duration': 5000,
      });
      expect(a.type, MaxAttachType.video);
      expect(a.token, 'tok');
      expect(a.fileId, 42);
      expect(a.durationMs, 5000);
      expect(a.status, MaxAttachStatus.uploaded);
    });

    test('unknown type falls back to FILE', () {
      final a = MaxAttach.fromServer({'_type': 'UNKNOWN_FUTURE_TYPE'});
      expect(a.type, MaxAttachType.file);
    });

    test('db roundtrip', () {
      final a = MaxAttach(
        type: MaxAttachType.audio,
        status: MaxAttachStatus.uploading,
        durationMs: 7777,
        progress: 0.42,
      );
      final m = a.toDbMap();
      final back = MaxAttach.fromDbRow({
        ...m,
        'rowid_pk': 1,
      });
      expect(back.type, MaxAttachType.audio);
      expect(back.status, MaxAttachStatus.uploading);
      expect(back.durationMs, 7777);
      expect(back.progress, closeTo(0.42, 1e-9));
    });
  });
}
