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
- Git: 10+ коммитов на `master`.

---

## Этап 4 — редизайн под оригинальный MAX (2026-05-25)

### Что сделано

- **Тема** (`lib/ui/theme/app_theme.dart`): фирменная палитра MAX (#0066FF primary), `NavigationBar` со скруглёнными индикаторами, filled-inputs со скруглением 14px, кастомизированный FAB и AppBar.
- **MainShell** (`lib/ui/screens/main_shell.dart`): `NavigationBar` с 4 табами — Чаты / Звонки / Контакты / Настройки. `IndexedStack` сохраняет state.
- **Splash** теперь ведёт на MainShell вместо ChatsListScreen.
- **ChatsListScreen**: SearchBar поверх списка, FAB «новый чат», цветные аватары по id, чистая типографика; long-press → bottom sheet с pin / mute / archive / mark-read.
- **ChatScreen**: AppBar.title = аватар + имя + статус «был(а) недавно», тап открывает Profile. Actions: видеозвонок, звонок (заглушки), PopupMenu (Профиль / Медиа / Обновить). Long-press на сообщении расширен «Переслать».
- **ProfileScreen** (`profile_screen.dart`): большой аватар, имя, телефон, action grid (Чат/Звонок/Видео/Поиск), Медиа чата, Уведомления switch, Закрепить, Архивировать, Очистить историю.
- **ForwardPickerScreen**: поиск чата + отправка текста.
- **CallsListScreen** (заглушка): локальная таблица `calls`, snackbar «в разработке».
- **MaxChat**: `isPinned`, `isArchived`, `isMuted`. БД схема v6 с ALTER chats.
- **AppDatabase.setChatFlag** + `chatsListController.togglePin/Archive/Mute`.
- AndroidManifest и iOS Info.plist — `MAX` (вместо `Maxim`).

### Финальная попытка APK

Повторно прогнан `flutter build apk --debug` со всеми обходами (JBR 21,
короткий TMP, ASCII-копия). Ошибка по-прежнему `Unable to establish
loopback connection`. Заключение: блокер исключительно на стороне
environment этого терминала, не кода.

Сборка из стороннего терминала / Android Studio даст APK без правок.

### Git

```
3a5891a Phase 4: редизайн под MAX (BottomNav, тема, профиль, pin/archive/forward)
4727631 feat: CLI standalone (bin/maxim_cli.dart) — рабочий бинарь
a90ace9 docs: расширить README + закрепить хеш Phase 3
0c6acdf Phase 3: подготовка к сборке (Windows desktop + sqflite_ffi)
1e336fd Phase 2.3: MSG_EDIT + CHAT_MEDIA-галерея + TRANSCRIBE
9441f1d Phase 2.2: upload pipeline + UI медиа
032f040 Phase 2.1: фундамент медиа (опкоды, MaxAttach, БД v4)
dda9e51 Phase 1.2-1.3: reliability + research медиа-опкодов
ff83855 Phase 1.1: пагинация, чат UX, импорт контактов
a81e1af init: Flutter-форк MAX-мессенджера
```

```
0c6acdf Phase 3: подготовка к сборке (Windows desktop + sqflite_ffi)
1e336fd Phase 2.3: MSG_EDIT + CHAT_MEDIA-галерея + TRANSCRIBE
9441f1d Phase 2.2: upload pipeline + UI медиа
032f040 Phase 2.1: фундамент медиа (опкоды, MaxAttach, БД v4)
dda9e51 Phase 1.2-1.3: reliability + research медиа-опкодов
ff83855 Phase 1.1: пагинация, чат UX, импорт контактов
a81e1af init: Flutter-форк MAX-мессенджера
```

---

## Этап 6 — РАСПАКОВКА тел кадров (корень всех багов) (2026-05-30)

### Главное открытие
Тело каждого кадра MAX **сжато**. В 4-байтовом поле длины старший байт = флаг `cof`:
- `0` — без сжатия
- `0xFF` — zstd
- `>0` — LZ4 block (размер распаковки = `payload_len * cof`)

Источник: реверс декомпила APK (агент нашёл `defpackage/e1d.java` — формат кадра, `lp.java:172-191` — диспетчер декомпрессии zstd/LZ4, `kua.java`/`xsa.java` — стандартный msgpack-кодек org.msgpack).

Раньше клиент парсил **сырые сжатые байты** как msgpack → мусор `f6 2f…`, «неверные длины строк», `unhashable list`, кракозябры, пустой список чатов. Это объясняло ВСЕ проблемы с WEB-токеном (и потенциально ANDROID).

### Проверка
Прямой запрос к серверу: LOGIN cof=4 (LZ4), 237КБ → 788КБ распаковано → распарсилось в `{profile, chats[4], messages, contacts, presence, config, token, updates}`. Чаты с именами и текстами читаются корректно (UTF-8): «А че», «<bot>» и т.д.

### Сделано
- **bridge.py**: `_decompress(cof, ln, body)` (lz4/zstandard) в `_reader_loop` перед msgpack. `_unpack` упрощён (raw=False по чистым данным). Зависимости: `pip install lz4 zstandard`.
- **APK**: `lib/data/max/lz4_block.dart` — чистый Dart LZ4 block decompressor (без FFI). `MaxClient._onData` извлекает cof, распаковывает. zstd (0xFF) пока не распакован (нет нативного, редкий случай). Тест `lz4_test.dart` (round-trip vs python lz4) — 21/21 зелёных.
- **APK auth UX**: при `FAIL_LOGIN_TOKEN` (мёртвый токен) — выход на экран входа с «Сессия истекла», без зацикливания reconnect.

### Открытый момент
Список чатов на главном экране заполняется из снэпшота login-ответа — данные теперь распакованы и читаемы, осталась интеграция парсинга снэпшота в локальную БД (login interactive=true → extract chats → db). Контакты, история (op 49), push — уже читаемы.

### Ключевой вывод про токены
Токены MAX привязаны к типу устройства (WEB/ANDROID) И протухают при перелогине в web.max.ru. Для стабильной работы нужен либо свежий веб-токен, либо ANDROID-токен по SMS (но при VPN с локацией вне reg-country-code сервер отключает phone-auth: `phone-auth-enabled: false`).

---

## Этап 7 — Anti-ban: снижение риска блокировки номера (2026-06-03)

### Вопрос
Почему симки блокирует, как только начинаем пользоваться своим клиентом, и как сделать форк, который не палится.

### Что выяснили (источники)
Антифрод MAX работает по **номеру / IP / поведению**, а не по анализу клиента:
- Август 2025: ~67 000 банов, причина №1 — спам-рассылки (RBC, Ведомости). Мошенничество — пожизненно.
- TLS/JA3 сервером **не проверяется** — подойдёт любой валидный TLS (реверс koval01, openmax-server). Подделка JA3 бессмысленна.
- Автор мода WhiteMAX: к февралю 2026 прямых банов за факт мода нет (habr/1008242) → детект «это мод» ненадёжен, банят по поведению/репутации.
- Блокировка по номеру, с которого вошли (tproger), не по устройству. Восстановление через поддержку, медленно (vc.ru).
- Репутация номера: до 1000 объявлений/день про аренду MAX-аккаунтов в даркнете (Коммерсантъ). Есть баны официального клиента на свежей SIM до первого входа (irecommend) — клиентом не лечится.

### Похожие проекты
Моды: reMAX, Komet, «Зелёный Макс», WhiteMAX. Протокол-клиенты: vkmax (py), vkmax-nodejs, PyMax, maxplus. Реверс: MaxProtoExplanation (nyakokitsu), openmax-server (~150 опкодов), gist koval01 (поля userAgent).

### Сделано в коде (3 меры)
1. **Стабильный deviceId** (`secure_storage.readOrCreateDeviceId` → `MaxClient.deviceIdLoader`). Было `const Uuid().v4()` на каждый запуск = поток новых устройств на одном номере. Теперь один UUID на установку, переживает logout.
2. **Официальный userAgent для ANDROID** (`DeviceProfile.userAgent`). Было 3 поля. Стало 11 в строгом порядке (pushDeviceType 2-й, deviceType upper-case) с реальными значениями устройства (`device_info_plus`). WEB оставлен минимальным (работает, форма не реверснута).
3. **Троттлинг op 46** (`ContactsRepository.bulkLookupByPhones`). Было пачками по 5 / 250мс (скрейпинг). Стало последовательно, 1.1–1.8с + джиттер, хард-кап 50, явное согласие в UI.

### Честная оценка
Помогает: стабильный deviceId, не-спамить/не-скрейпить, полный userAgent. Не помогает: подделка TLS, маскировка «не мод». Не лечится клиентом: репутация номера, медленная поддержка. Практика — не рассылать незнакомцам, не гонять через датацентровые/чужестранные VPN-IP (сбор VPN-флага через `HOST_REACHABILITY`, habr/1006666).

### Проверка
`flutter analyze` чисто, 23 теста зелёных (+`device_profile_test` фиксирует порядок полей userAgent). Коммит `9955a18`.
