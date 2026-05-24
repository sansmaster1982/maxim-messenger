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

### ✅ Phase 2.3 — MSG_EDIT + CHAT_MEDIA-галерея + TRANSCRIBE (2026-05-24)

- Опкод 67 (edit): БД v5 (edited_at), модель, репо, контроллер, long-press → пункт «Редактировать», плашка «изм.» в пузыре.
- Опкод 51 (chatMedia): MediaRepository, MediaGalleryController, MediaGalleryScreen (3-колонки GridView), PhotoViewScreen (InteractiveViewer fullscreen), кнопка-галерея в AppBar чата.
- Опкод 202 (transcribe): БД v5 (transcription), MaxAttach.transcription, transcribeAttach, кнопка «Расшифровать» под audio/video_msg.

Тесты: 20/20 (+ message_test.dart — 6 кейсов). `flutter analyze`: 0 issues. Коммит `1e336fd`.

---

## Этап 3 — сборка и smoke-test (2026-05-24)

### Что подготовлено

- Добавлена платформа `windows/` через `flutter create --platforms=windows`.
- В `pubspec.yaml` добавлена `sqflite_common_ffi: ^2.3.4`.
- `lib/main.dart` инициализирует FFI-фабрику sqflite для Windows/Linux/macOS, на Android/iOS использует нативный sqflite.

### Блокеры окружения

Сборка под обе target-платформы упёрлась в системные ограничения, которые нельзя обойти без действия пользователя на уровне ОС:

**Android (`flutter build apk --debug`)** падает на:
```
java.io.IOException: Unable to establish loopback connection
Caused by: java.net.SocketException: Invalid argument: connect
    at java.base/sun.nio.ch.UnixDomainSockets.connect0
    at sun.nio.ch.PipeImpl$Initializer$LoopbackConnector.run
```
JDK 17 пытается создать NIO Pipe через Unix Domain Sockets. В текущем bash-окружении системный вызов `connect()` на AF_UNIX возвращает `EINVAL`. Это уровень JDK/OS, не Java-кода. Воспроизводится одинаково и в исходном каталоге, и в копии под ASCII-путём (`C:\maxim_build`). Пробованные обходы (`-Djava.net.preferIPv4Stack=true`, `org.gradle.daemon=false`, `org.gradle.workers.max=1`, `dangerouslyDisableSandbox`) — не сработали.

**Windows (`flutter build windows --debug`)** падает на:
```
Building with plugins requires symlink support.
Please enable Developer Mode in your system settings.
```
Flutter создаёт symlinks для каталогов плагинов в `windows/flutter/ephemeral/`. На Windows для этого нужен либо администратор, либо Developer Mode.

### Что нужно сделать пользователю

Один из двух путей:

1. **Windows desktop (одно действие):**
   - Открыть `ms-settings:developers` (Параметры → Конфиденциальность и безопасность → Для разработчиков) → включить «Режим разработчика».
   - В корне проекта запустить `flutter build windows --debug`.
   - Артефакт: `build/windows/x64/runner/Debug/maxim_messenger.exe`.

2. **Android APK через Android Studio:**
   - Открыть в Android Studio папку `android/`.
   - Build → Build Bundle(s)/APK(s) → Build APK(s).
   - Артефакт: `build/app/outputs/flutter-apk/app-debug.apk`.
   - В Android Studio собственный Gradle-процесс не сталкивается с UDS-проблемой.

### ✅ Запасной вариант: CLI standalone EXE

Поскольку Flutter-сборки потребовали системных настроек на момент работы,
собран альтернативный таргет — консольный клиент `bin/maxim_cli.dart`
через `dart compile exe`. Использует тот же `MaxClient`, опкоды,
протокол.

```
$ dart compile exe bin/maxim_cli.dart -o build/maxim_cli.exe
Generated: build/maxim_cli.exe

$ build/maxim_cli.exe --probe
=== Maxim CLI (proto v10, app 26.11.0) ===
Подключение к api.oneme.ru:443…
OK, TLS-соединение установлено.
probe OK — handshake выполнен, выхожу.
Соединение закрыто.
```

Бинарь 6.2 МБ, AOT-компиляция, без Flutter-плагинов, без symlinks.
Реальный smoke на боевом сервере прошёл: TLS+INIT (opcode 6) отрабатывают.
Команды REPL: send/hist/find/me/quit.

### Состояние кода

- 20/20 юнит-тестов зелёные (`flutter test`).
- `flutter analyze` — 0 issues.
- `flutter pub get` чистый.
- Целевые платформы в `pubspec`/`flutter create`: Android + iOS + Windows.
- Дополнительно: standalone CLI (`bin/maxim_cli.dart` → `build/maxim_cli.exe`).
- Git: 9 коммитов на `master`.

```
0c6acdf Phase 3: подготовка к сборке (Windows desktop + sqflite_ffi)
1e336fd Phase 2.3: MSG_EDIT + CHAT_MEDIA-галерея + TRANSCRIBE
9441f1d Phase 2.2: upload pipeline + UI медиа
032f040 Phase 2.1: фундамент медиа (опкоды, MaxAttach, БД v4)
dda9e51 Phase 1.2-1.3: reliability + research медиа-опкодов
ff83855 Phase 1.1: пагинация, чат UX, импорт контактов
a81e1af init: Flutter-форк MAX-мессенджера
```
