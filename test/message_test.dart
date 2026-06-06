import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/data/max/models/attach.dart';
import 'package:maxim_messenger/data/max/models/message.dart';

void main() {
  group('MaxMessage editedAt roundtrip', () {
    test('toMap includes edited_at when set', () {
      const m = MaxMessage(
        id: 42,
        chatId: 1,
        text: 'updated',
        timeMs: 1000,
        direction: MessageDirection.outgoing,
        editedAtMs: 2000,
      );
      final map = m.toMap();
      expect(map['edited_at'], 2000);
      expect(map['text'], 'updated');
    });

    test('fromDbRow reads edited_at', () {
      final m = MaxMessage.fromDbRow({
        'id': 7,
        'local_id': null,
        'chat_id': 5,
        'sender_id': 100,
        'text': 'edited body',
        'time_ms': 1234,
        'direction': 'outgoing',
        'status': 'sent',
        'reply_to_id': null,
        'reply_to_preview': null,
        'edited_at': 99999,
      });
      expect(m.editedAtMs, 99999);
      expect(m.text, 'edited body');
    });

    test('default editedAt is null when message never edited', () {
      const m = MaxMessage(
        chatId: 1,
        text: 'fresh',
        timeMs: 0,
        direction: MessageDirection.incoming,
      );
      expect(m.editedAtMs, isNull);
      expect(m.toMap()['edited_at'], isNull);
    });

    test('copyWith preserves and overrides editedAt', () {
      const m = MaxMessage(
        chatId: 1,
        text: 'orig',
        timeMs: 0,
        direction: MessageDirection.outgoing,
      );
      final edited = m.copyWith(text: 'new', editedAtMs: 555);
      expect(edited.editedAtMs, 555);
      expect(edited.text, 'new');
      final reset = edited.copyWith();
      expect(reset.editedAtMs, 555);
    });
  });

  group('MaxAttach transcription roundtrip', () {
    test('toDbMap includes transcription field', () {
      const a = MaxAttach(
        type: MaxAttachType.audio,
        transcription: 'привет мир',
      );
      final m = a.toDbMap();
      expect(m['transcription'], 'привет мир');
    });

    test('fromDbRow reads transcription', () {
      final a = MaxAttach.fromDbRow({
        'rowid_pk': 1,
        'type': 'AUDIO',
        'status': 'uploaded',
        'transcription': 'hello',
      });
      expect(a.transcription, 'hello');
      expect(a.type, MaxAttachType.audio);
    });
  });
}
