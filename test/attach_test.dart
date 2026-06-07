import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/data/max/models/attach.dart';

void main() {
  group('MaxAttach', () {
    test('photo server payload is minimal {_type, photoToken}', () {
      // Реальный MAX (c60.java + dbd.java) шлёт для ФОТО ровно _type+photoToken,
      // без size/width/baseUrl — сервер достаёт их по токену.
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
      expect(payload['photoToken'], 'abc');
      expect(payload.containsKey('token'), isFalse);
      expect(payload.containsKey('size'), isFalse);
      expect(payload.containsKey('width'), isFalse);
    });

    test('fromServer builds display url from baseUrl with &fn=w_720', () {
      final a = MaxAttach.fromServer({
        '_type': 'PHOTO',
        'baseUrl': 'https://i.oneme.ru/p.jpg?token=xyz',
        'width': 800,
        'height': 600,
      });
      expect(a.type, MaxAttachType.photo);
      expect(a.downloadUrl, 'https://i.oneme.ru/p.jpg?token=xyz&fn=w_720');
      expect(a.width, 800);
    });

    test('fromServer prefers explicit photoUrl over baseUrl', () {
      final a = MaxAttach.fromServer({
        '_type': 'PHOTO',
        'photoUrl': 'https://i.oneme.ru/direct.jpg',
        'baseUrl': 'https://i.oneme.ru/p.jpg?token=xyz',
      });
      expect(a.downloadUrl, 'https://i.oneme.ru/direct.jpg');
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
