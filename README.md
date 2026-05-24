# Maxim — кросс-платформенный клиент MAX

Форк-клиент мессенджера MAX (api.oneme.ru) для Android и iOS, написанный
на Flutter. Использует реверс-инжиниринг протокола из проекта
`telega-to-max` (Python).

## Статус

- 0.1.0, MVP-фундамент.
- Текстовые сообщения: отправка, приём (push), история, поиск контактов
  по номеру, авторизация (SMS + 2FA), повторный вход по сохранённому
  токену.
- Локальное хранилище: SQLite + Secure Storage для токена.
- iOS и Android из одной кодовой базы.
- Что не сделано: загрузка/скачивание медиа, голосовые, звонки, реакции,
  группы (видны как обычный чат, но без специфики), системные события,
  push-нотификации через FCM/APNs.

## Стек

- Flutter 3.29+, Dart 3.7+.
- State: Riverpod 2.
- БД: sqflite. Токен: flutter_secure_storage.
- Сеть: SecureSocket (TLS), msgpack_dart.

## Структура

```
lib/
  core/                константы протокола и исключения
  data/
    max/               клиент протокола MAX
      max_client.dart  TCP+TLS, фреймы, опкоды, push
      max_codec.dart   упаковка/распаковка кадров
      raw_parsers.dart парсеры msgpack-полей по сырому байту
      models/          IncomingMessage, MaxChat, MaxMessage, MaxContact
    local/             SQLite + secure storage
    repositories/      auth/chats/contacts/messages
  state/               Riverpod-провайдеры и контроллеры
  ui/
    screens/           splash, login, chats, chat, contacts, settings
    widgets/           message_bubble, chat_input
    theme/             светлая/тёмная тема Material 3
```

## Опкоды протокола MAX

Известны и реализованы:

| Опкод | Назначение                  |
|-------|-----------------------------|
| 6     | INIT (handshake)            |
| 16    | PROFILE (мой профиль)       |
| 17    | AUTH_REQUEST (SMS)          |
| 18    | AUTH_CONFIRM (код)          |
| 19    | LOGIN (по токену)           |
| 32    | CONTACT_INFO (по id)        |
| 46    | CONTACT_INFO_BY_PHONE       |
| 48    | CHAT_INFO                   |
| 49    | CHAT_HISTORY                |
| 51    | CHAT_MEDIA (галерея чата)   |
| 64    | SEND_MESSAGE (+attaches)    |
| 65    | TYPING                      |
| 67    | MSG_EDIT                    |
| 80    | PHOTO_UPLOAD                |
| 81    | STICKER_UPLOAD              |
| 82    | VIDEO_UPLOAD                |
| 83    | VIDEO_PLAY                  |
| 87    | FILE_UPLOAD                 |
| 88    | FILE_DOWNLOAD               |
| 115   | 2FA_PASSWORD                |
| 202   | TRANSCRIBE_MEDIA            |

Детальная таблица с источниками — `docs/MEDIA_OPCODES.md`. Журнал
прогресса разработки — `docs/PROGRESS.md`.

## Установка и запуск

Зависимости:
```
flutter pub get
```

### Android (требуется Android SDK + Java 17)

```
flutter run -d <device-id>
# или
flutter build apk --debug
```

Если `flutter build apk` падает с `Unable to establish loopback connection`
в текущем терминале — собирай через Android Studio: File → Open → выбрать
папку `android/`, Build → Build APK(s). Это известная проблема среды
(JDK NIO UDS), Android Studio её обходит собственным Gradle-daemon.

### iOS (требуется macOS + Xcode)

```
cd ios && pod install && cd ..
flutter run -d <device-id>
```

### Windows desktop (Flutter UI)

Требует **Developer Mode** включённого в Windows (для symlink-плагинов).

1. `start ms-settings:developers` → включить «Режим разработчика».
2. Перелогиниться (или открыть свежий терминал — privilege-token обновляется только в новом logon-сеансе).
3. `flutter build windows --debug`
4. Артефакт: `build/windows/x64/runner/Debug/maxim_messenger.exe`

На desktop:
- Импорт контактов и снимок с камеры недоступны (платформенные плагины).
- Текст, история, файлы через file_picker — работают.
- SQLite через `sqflite_common_ffi` (нативная DLL, не Android).

### CLI (standalone EXE, без Flutter)

`bin/maxim_cli.dart` — полнофункциональный консольный клиент, использует
тот же `MaxClient`. Не требует Developer Mode и Android-toolchain.

```
dart compile exe bin/maxim_cli.dart -o build/maxim_cli.exe
```

Получается ~6 МБ AOT-скомпилированный exe. Smoke:

```
build/maxim_cli.exe --probe      # TLS-хендшейк + INIT, без логина
build/maxim_cli.exe --version
build/maxim_cli.exe               # интерактивный REPL
```

REPL-команды:
- `send <chatId> <text...>` — отправить сообщение
- `hist <chatId> [count]` — последние N сообщений
- `find <phone>` — найти контакт по номеру
- `me` — мой профиль
- `quit` — выход

Токен после первого логина кладётся в `max_token.txt` рядом с exe.

## Авторизация

1. Открыть приложение, ввести номер в формате `+79991234567`.
2. Ввести код из SMS.
3. Если у аккаунта включён пароль 2FA, ввести его.

После успешного входа токен лежит в Keystore/Keychain (Secure Storage).
При повторном запуске сессия восстанавливается автоматически.

## Версии протокола

Зашиты в `lib/core/constants.dart`:
```
host = api.oneme.ru
proto_version = 10
app_version = 26.11.0
```

Когда официальное приложение MAX выпустит мажорное обновление, может
потребоваться поднять `app_version`.

## Безопасность

- Токен хранится в Android Keystore / iOS Keychain.
- Сетевой трафик к `api.oneme.ru` идёт через TLS.
- Локальная SQLite — без шифрования (на телефоне защищена системным
  шифрованием диска). Если нужен прицельный E2E — добавить SQLCipher.

## Git

Репозиторий инициализирован. Откат:
```
git log --oneline
git checkout <commit>
```

Для нормальной работы — ветка `main`, фичевые ветки от неё.

## TODO следующих итераций

1. Опкоды медиа (поднять из декомпила APK).
2. Push-нотификации (FCM Android, APNs iOS).
3. Голосовые сообщения.
4. Реакции, ответы на сообщение, пересылка.
5. Группы (members, аватары, права).
6. Тайпинг-индикатор от собеседника (приходит ли в push — проверить).
7. Дешифровка ASN.1/E2E если он есть в MAX (пока не проверено).
