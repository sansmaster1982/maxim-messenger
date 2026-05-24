# MAX мессенджер — медиа-опкоды бинарного протокола

Источник: декомпил `apk_check/max_full_decompiled/sources/`.
Главный enum опкодов: `defpackage/ewc.java`. Опкоды лежат как `short` константы в
конструкторе `new ewc(NAME, ordinal, opcode, parser)`. Базовый класс билдера
запроса — `defpackage/t3.java`; payload пишется в `tx` (msgpack map) методами
`c/d/e/f/g/h/i/j` (bool/byte/int/list/long-array/long/map/string).

Запрос на сетевом уровне состоит из `(short opcode, msgpack map payload)`.
Ответы парсятся обработчиками типа `n7l`, `stb`, `my3` и т.п. (см. третий
параметр конструктора `ewc`).

## Таблица опкодов

| Опкод | Имя              | Payload (поля)                                                                                                       | Источник (файл:строка)                                                | Уверенность |
| ----- | ---------------- | -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | ----------- |
| 51    | CHAT_MEDIA       | `{chatId, messageId, attachTypes:[PHOTO/VIDEO/AUDIO/SHARE/APP/CALL/FILE/CONTACT/PRESENT/INLINE_KEYBOARD/LOCATION/REPLY_KEYBOARD/VIDEO_MSG/POLL], forward?, backward?}` | `defpackage/ewc.java:80`, `defpackage/fy2.java:429-492`               | высокая     |
| 64    | MSG_SEND         | `{chatId?, userId?, message:{cid, text?, detectShare, attaches?:[...], link?, isLive, elements?, delayedAttributes?}, notify?, lastKnownDraftTime?}` | `defpackage/ewc.java:94`, `defpackage/zg9.java:206-222`, `defpackey/lzc.java:28-54` | высокая     |
| 67    | MSG_EDIT         | `{chatId, messageId, text?, attachments?, elements?, delayedAttributes?}`                                            | `defpackage/ewc.java:97`, `defpackage/zg9.java:168-186`               | высокая     |
| 80    | PHOTO_UPLOAD     | `{count, profile:bool}` — запрос upload-URL. Ответ возвращает upload URL + `photoToken` для дальнейших операций.     | `defpackage/ewc.java:115`, `defpackage/zg9.java:33-101` (case 17), `defpackage/zg9.java:138-144` | высокая     |
| 81    | STICKER_UPLOAD   | Стандартный билдер `t3` с `ewc.Y1` (поля не выявлены — конструктор не найден явно)                                   | `defpackage/ewc.java:116`, `defpackage/zg9.java:95-97` (case 26)      | средняя     |
| 82    | VIDEO_UPLOAD     | `{type, count, uploaderType}` — запрос параметров видео-аплоада, ответ парсится через `my3.k`                        | `defpackage/ewc.java:117`, `defpackage/kdj.java:29-36`                | высокая     |
| 83    | VIDEO_PLAY       | `{videoId, chatId?, messageId?, token?}` — получить URL воспроизведения видео                                        | `defpackage/ewc.java:118`, `defpackage/kdj.java:38-53`                | высокая     |
| 87    | FILE_UPLOAD      | Стандартный билдер `t3` с `ewc.d2`. Поля payload в декомпиле не выявлены явно (нет специализированного конструктора). | `defpackage/ewc.java:121`                                             | средняя     |
| 88    | FILE_DOWNLOAD    | Запрос: `{fileId, chatId, messageId}`. Ответ: `{url, unsafe}` (см. `n7l.l()`)                                        | `defpackage/ewc.java:122`, `defpackage/fy2.java:410-416`, `defpackage/n7l.java:179-355` | высокая     |
| 136   | NOTIF_ATTACH     | Push-нотификация от сервера о новом attach (парсер `utb.h`)                                                          | `defpackage/ewc.java:149`                                             | средняя     |
| 202   | TRANSCRIBE_MEDIA | `{mediaId, messageId, chatId}` — запрос на расшифровку аудио/видео-сообщения                                        | `defpackage/ewc.java:193`, `defpackage/zg9.java:188-195`, `defpackage/kpi.java:41` | высокая     |
| 293   | NOTIF_TRANSCRIPTION | Push-нотификация о готовой транскрипции (парсер `swb.a`)                                                          | `defpackage/ewc.java:194`                                             | средняя     |

## Структура attach внутри `MSG_SEND.message.attaches`

Каждый attach — это msgpack-map с обязательным полем `_type`. Базовый класс
`defpackage/c60.java:122-126`:

```java
HashMap a() {
    HashMap m = new HashMap();
    m.put("_type", this.a.a);  // строка из enum x70
    return m;
}
```

Возможные значения `_type` (из `defpackage/x70.java:11-29`):
`UNKNOWN, CONTROL, PHOTO, VIDEO, AUDIO, STICKER, SHARE, APP, CALL, FILE,
CONTACT, PRESENT, INLINE_KEYBOARD, LOCATION, REPLY_KEYBOARD, VIDEO_MSG,
WIDGET, POLL`.

### `_type=PHOTO` (`defpackage/dbd.java:33-40`)

```
{ "_type":"PHOTO", "photoToken":"..." }
```

Дополнительные поля (id, width, height, hash, thumbhash) хранятся локально,
но в сетевой payload идёт только `photoToken`.

### `_type=VIDEO` (`defpackage/lcj.java:45-68`)

```
{
  "_type":"VIDEO",
  "videoId" | "token",    // одно из двух (token, если файл уже залит)
  "videoType": int,
  "wave"?: bytes,
  "duration"?: long,
  "thumbhash"?: bytes
}
```

### `_type=AUDIO` (`defpackage/p90.java:23-41`)

```
{
  "_type":"AUDIO",
  "audioId" | "token",
  "wave"?: bytes,
  "duration"?: long
}
```

### `_type=FILE` (`defpackage/bq6.java:23-33`)

```
{ "_type":"FILE", "fileId" | "token" }
```

Только один из двух — `fileId` (если файл уже на сервере) или `token`
(post-upload идентификатор от UPLOAD_URL).

### `_type=STICKER` (`defpackage/qlh.java:43-48`)

```
{ "_type":"STICKER", "stickerId": long }
```

### `_type=CONTROL` (`defpackage/zs4.java:43-136`)

Системный attach для событий чата (`new`, `add`, `remove`, `title`, `icon`,
`pin`, ...). При смене аватарки чата сюда кладётся `photoToken`.

```
{
  "_type":"CONTROL",
  "event": "new" | "add" | "remove" | "title" | "icon" | "joinByLink" | "pin" | ...,
  "userId"?, "userIds"?, "title"?, "photoToken"?, "crop"?,
  "showHistory"? (только для add),
  "chatType"? ("UNKNOWN" | "DIALOG" | "CHAT" | "CHANNEL" | "GROUP_CHAT"),
  "startPayload"?
}
```

## Как сервер отдаёт результат upload

Сценарий загрузки медиа в MAX **двухступенчатый**:

1. Клиент шлёт `PHOTO_UPLOAD` (80) / `VIDEO_UPLOAD` (82) / `FILE_UPLOAD` (87) /
   `STICKER_UPLOAD` (81). В ответе сервер возвращает **upload URL** (HTTP).
2. Клиент POST'ит бинарник файла на этот URL (см. `defpackage/vvc.java`,
   `defpackage/tvc.java` — это OneVideo-uploader для видео/аудио; для фото —
   аналогичный multipart HTTP). В ответе HTTP сервер возвращает идентификатор
   ресурса:
   - `photoToken` — для фото
   - `token` (он же `videoToken` / `audioToken`) — для видео/аудио
   - `token` (он же `fileToken`) — для файлов
   - `videoId` / `audioId` / `fileId` — для уже загруженных ранее
3. Этот токен подкладывается в `attach` внутри `MSG_SEND` (опкод 64).

Поле `photo_token` хранится локально в Room DB в таблице `uploads`
(`defpackage/enc.java:25`):

```sql
CREATE TABLE uploads (
  attach_local_id TEXT, prepared_path TEXT, file_name TEXT,
  upload_url TEXT, upload_progress REAL NOT NULL, total_bytes INTEGER NOT NULL,
  upload_status INTEGER, created_time INTEGER NOT NULL,
  path TEXT NOT NULL, last_modified INTEGER NOT NULL, upload_type INTEGER NOT NULL,
  photo_token TEXT, attach_id INTEGER, thumbhash_base64 TEXT,
  desired_uploader TEXT,
  PRIMARY KEY(path, last_modified, upload_type)
)
```

Для **FILE_DOWNLOAD** (88) схема одношаговая: клиент шлёт
`{fileId, chatId, messageId}`, сервер возвращает `{url, unsafe}`. Парсер ответа —
`defpackage/n7l.java:179-355` (метод `l()`). Поле `unsafe:bool` — флаг
небезопасного файла (есть отдельный warning UI: `one.me.filedownloadwarning`).

## Что НЕ найдено в декомпиле

- **STICKER_UPLOAD (81)** — опкод присутствует в `ewc.java:116`, но
  специализированного конструктора билдера `zg9` для него нет; payload собирается
  внешне через `t3.j/h/e/...`. Скорее всего поля похожи на PHOTO_UPLOAD
  (`{count}` + специфика стикера). Конкретные поля надо ловить по pcap.
- **FILE_UPLOAD (87)** — то же самое: опкод есть (`ewc.d2`), специализированный
  билдер не найден. Вероятно поля: `{fileName, fileSize, mimeType}` — но в
  декомпиле этого фиксированного списка не обнаружено.
- **Отдельный VOICE/voice-message opcode** не найден. Голос идёт как
  `_type=AUDIO` или `_type=VIDEO_MSG` (см. `x70.VIDEO_MSG`) внутри MSG_SEND.
  Поле `uploadType` в `kdj(int, int)` (VIDEO_UPLOAD) поддерживает 3 типа
  (`vvc.java:39-41`): `VIDEO`, `VIDEO_MESSAGE`, `AUDIO` — все через тот же
  опкод 82 с разным `type`.
- **GIF** как отдельный опкод не найден. В DB схема (`enc.java`) есть таблицы
  `recent` с полем `gif BLOB`, но это локальный кэш недавно использованных. На
  wire-уровне GIF, скорее всего, едет как `_type=STICKER` (видно по `qlh.java`,
  где `mp4_url`, `lottie_url`, `video_url` присутствуют в DB-схеме стикеров) или
  обычный PHOTO/VIDEO attach.

## Дополнительные ограничения и константы

- Минимальный размер файла для аплоада: > 0 (нулевой файл отбивается с
  `HttpErrorException("File is zero length")` в `defpackage/vvc.java:60-66`).
- Существует таблица error-кодов аплоада в `defpackage/q6j.java`:
  - 100 `UNKNOWN_ATTACH`, 101 `ATTACH_OR_MSG_DELETED`,
  - 200/201 `ERROR_DURING_CONVERT/CONVERTED_FILE_DISAPPEARED`,
  - 300-306 ошибки URI и копирования,
  - 307-312 ошибки загрузки (`UPLOAD_INVALID_RESULT_STATE`,
    `UPLOAD_FILE_EMPTY`, `UPLOAD_TIMEOUT`, `UPLOAD_MAX_RETRY_COUNT`,
    `UPLOAD_UNKNOWN_ERROR`, `DEGRADATION_BLOCKED`).
- Категории файл-стораджа (`defpackage/oa1.java`): `ROOT, IMAGES, AUDIO, GIF,
  STICKERS, UPLOAD, MUSIC, VIDEO, RINGTONE, RINGTONE_FILES, OTHERS` — клиентский
  организационный enum, не идёт по wire.
- В `defpackage/fy2.java:439-484` есть полное соответствие enum'а `x70` к
  строковым типам, которые идут в `CHAT_MEDIA.attachTypes`: `PHOTO`, `VIDEO`,
  `AUDIO`, `SHARE`, `APP` (через `GrsBaseInfo.CountryCodeSource.APP="HMS"`,
  хотя в реале это `"APP"`), `CALL`, `FILE`, `CONTACT`, `PRESENT`,
  `INLINE_KEYBOARD`, `LOCATION`, `REPLY_KEYBOARD`, `VIDEO_MSG`, `POLL`.

## Соседние нотификации от сервера (push)

| Опкод | Имя                 | Назначение                                                            |
| ----- | ------------------- | --------------------------------------------------------------------- |
| 128   | NOTIF_MESSAGE       | Новое сообщение в чате (с attaches внутри)                            |
| 130   | NOTIF_MARK          | Обновление прочитанности                                              |
| 136   | NOTIF_ATTACH        | Обновление статуса attach (например, видео доконвертилось на сервере) |
| 142   | NOTIF_MSG_DELETE    | Сообщение удалено                                                     |
| 155   | NOTIF_MSG_REACTIONS_CHANGED | Реакции изменились                                            |
| 293   | NOTIF_TRANSCRIPTION | Транскрипция аудио готова                                             |
