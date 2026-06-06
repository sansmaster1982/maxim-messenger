import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/data/max/models/attach.dart';
import 'package:maxim_messenger/data/max/models/upload_input.dart';

void main() {
  group('UploadInput.fromPath', () {
    test('jpg path resolves to photo', () {
      final u = UploadInput.fromPath('/tmp/sample.jpg');
      expect(u.type, MaxAttachType.photo);
      expect(u.mimeType, 'image/jpeg');
      expect(u.fileName, 'sample.jpg');
      expect(u.path, '/tmp/sample.jpg');
    });

    test('png path resolves to photo', () {
      final u = UploadInput.fromPath('C:/photos/cat.png');
      expect(u.type, MaxAttachType.photo);
      expect(u.mimeType, 'image/png');
    });

    test('mp4 path resolves to video', () {
      final u = UploadInput.fromPath('/tmp/clip.mp4');
      expect(u.type, MaxAttachType.video);
      expect(u.mimeType, 'video/mp4');
    });

    test('mp3 path resolves to audio', () {
      final u = UploadInput.fromPath('/tmp/song.mp3');
      expect(u.type, MaxAttachType.audio);
    });

    test('ogg falls into audio even when mime guesses video', () {
      // .ogg может детектиться как application/ogg или video/ogg;
      // наша эвристика всё равно отправит его как audio.
      final u = UploadInput.fromPath('/tmp/voice.ogg');
      expect(u.type, MaxAttachType.audio);
    });

    test('txt path resolves to file', () {
      final u = UploadInput.fromPath('/tmp/notes.txt');
      expect(u.type, MaxAttachType.file);
      expect(u.fileName, 'notes.txt');
    });

    test('unknown extension resolves to file', () {
      final u = UploadInput.fromPath('/tmp/blob.xyz123');
      expect(u.type, MaxAttachType.file);
    });
  });
}
