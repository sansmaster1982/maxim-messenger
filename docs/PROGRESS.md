# Maxim — журнал прогресса

Каждый шаг разработки фиксируется здесь: что сделано, чем верифицировано, какой коммит.

## Легенда

- ✅ — завершено и проверено (`flutter analyze` чистый, `flutter test` зелёный, коммит сделан).
- ⏳ — в работе.
- ❌ — заблокировано/откатано.

---

## Этап 0 — baseline (2026-05-24)

Создан Flutter-проект `maxim_messenger` в `max new maxim/`, инициализирован git, написано ядро MaxClient (порт `telega-to-max/max_client.py`), локальная БД, Riverpod, UI: splash/login/chats/chat/contacts/settings.

- Коммит: `a81e1af init: Flutter-форк MAX-мессенджера (Android+iOS)`
- Тесты: 2/2 ✅
- Опкоды: 6/16/17/18/19/32/46/48/49/64/65/115

---

## Этап 1 — история, контакты, переписки (2026-05-24)

### Phase 1.1 — пагинация истории + чат UX + импорт контактов

Параллельно два агента, разделение по файлам:
- **Agent A**: пагинация `chat_history(fromId)`, date-разделители, тайпинг outbound, reply на сообщение, длинный тап → bottom sheet.
- **Agent B**: `flutter_contacts ^1.1.9+2`, импорт адресной книги, bulk-lookup батчами по 5 (250мс пауза), поиск/фильтр, Dismissible-свайп, группировка по букве.

- Коммит: `ff83855`
- Тесты: 2/2 ✅
- Diff: 13 файлов, 1113+/71−, 2 новых файла.

### Phase 1.2 — Reliability (auto-reconnect + outbox)

- `MaxConnectionState` enum + Stream.
- `_ReconnectManager` с exponential backoff `2→4→8→16→32→60s`.
- `close()` (явно, навсегда) vs `_disconnect()` (только сокет, для reconnect).
- БД схема v3: таблица `outbox(local_id PK, chat_id, text, created_at, attempts)`.
- `drainOutbox` шедулится на переход в `connected`.
- `retryFailed(chatId)` для UI-тапа на failed-пузыре.
- `ConnectionBanner` в `ChatsListScreen`.

### Phase 1.3 — Research медиа-опкодов

- `docs/MEDIA_OPCODES.md` — 12 опкодов из декомпила APK.
- Ключевые: 51 CHAT_MEDIA, 64 MSG_SEND (с `attaches?`), 67 MSG_EDIT, 80 PHOTO_UPLOAD, 82 VIDEO_UPLOAD, 83 VIDEO_PLAY, 87 FILE_UPLOAD, 88 FILE_DOWNLOAD, 202 TRANSCRIBE_MEDIA.

- Коммит: `dda9e51`
- Тесты: 3/3 ✅ (+ `reconnect_test`).
- Diff: 11 файлов, 719+/66−, 4 новых файла.

---

## Этап 2 — медиа (в работе)

### ✅ Phase 2.1 — фундамент (2026-05-24)

- Опкоды 51/67/80/81/82/83/87/88/136/202/293 в `MaxOp`.
- Модель `MaxAttach` (type/status/token/fileId/mime/size/dimensions/duration/localPath/downloadUrl/progress) + методы `toServerPayload`, `toDbMap`, `fromDbRow`, `fromServer`.
- `MaxMessage.attaches: List<MaxAttach>` (через джойн отдельной таблицы).
- БД схема v4: таблица `attachments` (rowid PK, message_local_id?, message_server_id?, chat_id, type, status, token, file_id, mime_type, size_bytes, width, height, duration_ms, local_path, download_url, thumbnail_url, file_name, progress, created_at).
- `MaxClient`: методы `requestPhotoUpload`, `requestVideoUpload`, `requestFileUpload`, `requestVideoPlay`, `requestFileDownload`, `chatMedia`, `editMessage`, `transcribeMedia`. `sendMessage` принимает `attaches` + `replyToId`.
- `IncomingMessage.attaches`, `_parsePush` принимает сообщения без текста если есть attach.
- `MessagesRepository._persistAttaches` подключён к push и history.

Тесты: 7/7 (новый `attach_test.dart` — 4 case).
`flutter analyze`: 0 issues.

### ✅ Phase 2.2 — Upload pipeline + UI медиа (2026-05-24)

**Agent E (upload):** http ^1.2.2, mime ^2.0.0. `UploadInput.fromPath` определяет тип по mime. `UploadRepository.upload`: opcode 80/82/87 → upload URL → multipart HTTP POST → token. Прогресс 0→0.1→0.3→0.7→1.0. `MessagesRepository.sendMedia` создаёт pending msg, аплоадит attach'и один за другим, шлёт sendMessage(64) с `attaches`.

**Agent F (UI):** `AttachPicker.show` — bottom sheet с 5 опциями (фото/видео галерея, камера, файл). `AttachPreview` рисует attach по типу с прогресс-баром. `MessageBubble` показывает attaches над текстом. `downloadAttach` стримит файл через opcode 88/83 в `documents/maxim_media/`.

Тесты: 14/14 (`upload_input_test` — 7 case). `flutter analyze`: 0 issues. Коммит `9441f1d`.

### ⏳ Phase 2.3 — расширенные функции

MSG_EDIT (67), CHAT_MEDIA-галерея (51), TRANSCRIBE (202).

---

## Этап 3 — сборка и smoke-test

- `flutter doctor`, доустановка недостающих компонентов.
- `flutter build apk --debug` или `flutter run -d windows` для smoke-теста UI.
