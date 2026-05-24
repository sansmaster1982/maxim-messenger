// Maxim CLI — консольный клиент MAX-мессенджера.
//
// Использует тот же MaxClient, что и Flutter-приложение. Работает на
// Windows/Linux/macOS без графики, без Android-/Windows-toolchain.
// Сборка: `dart compile exe bin/maxim_cli.dart -o maxim_cli.exe`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';

import 'package:maxim_messenger/core/constants.dart';
import 'package:maxim_messenger/core/errors.dart';
import 'package:maxim_messenger/data/max/max_client.dart';
import 'package:maxim_messenger/data/max/models/incoming_message.dart';

Future<void> main(List<String> argv) async {
  stdout.writeln('=== Maxim CLI (proto v${MaxProto.protoVersion}, '
      'app ${MaxProto.appVersion}) ===');

  if (argv.contains('--version') || argv.contains('-v')) {
    stdout.writeln('host=${MaxProto.host}:${MaxProto.port}');
    stdout.writeln('build: standalone Dart AOT');
    return;
  }
  if (argv.contains('--help') || argv.contains('-h')) {
    stdout.writeln('Команды интерактивного REPL:');
    stdout.writeln('  send <chatId> <text...>');
    stdout.writeln('  hist <chatId> [count]');
    stdout.writeln('  find <phone>');
    stdout.writeln('  me');
    stdout.writeln('  quit');
    stdout.writeln('\nФлаги: --version, --help, --probe');
    stdout.writeln('--probe — установить TLS-соединение и сразу выйти.');
    return;
  }

  final tokenFile = File('max_token.txt');
  final client = MaxClient(
    logger: Logger(printer: SimplePrinter(printTime: true)),
  );

  try {
    stdout.writeln('Подключение к ${MaxProto.host}:${MaxProto.port}…');
    await client.connect();
    stdout.writeln('OK, TLS-соединение установлено.');

    if (argv.contains('--probe')) {
      stdout.writeln('probe OK — handshake выполнен, выхожу.');
      return;
    }

    final saved = tokenFile.existsSync()
        ? tokenFile.readAsStringSync().trim()
        : null;

    if (saved == null || saved.isEmpty) {
      await _interactiveLogin(client, tokenFile);
    } else {
      stdout.writeln('Логин по сохранённому токену…');
      try {
        await client.login(saved);
        stdout.writeln('Сессия восстановлена.');
      } on MaxLoginFailed catch (e) {
        stdout.writeln('Токен протух: $e. Повторный логин по SMS.');
        tokenFile.deleteSync();
        await _interactiveLogin(client, tokenFile);
      }
    }

    final me = await client.currentProfile();
    stdout.writeln('Вошёл как: id=${me['id']} name=${me['name']}');

    // Запустим listen в фоне — будет печатать входящие.
    final pushSub = client.incomingStream.listen(_printIncoming);

    stdout.writeln('\nКоманды:');
    stdout.writeln('  send <chatId> <text...>  — отправить сообщение');
    stdout.writeln('  hist <chatId> [count]    — последние N сообщений');
    stdout.writeln('  find <phone>             — найти контакт по номеру');
    stdout.writeln('  me                       — мой профиль');
    stdout.writeln('  quit                     — выход');

    final input = stdin.transform(utf8.decoder).transform(const LineSplitter());
    await for (final raw in input) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line == 'quit' || line == 'exit') break;

      try {
        await _runCommand(client, line);
      } catch (e) {
        stderr.writeln('Ошибка: $e');
      }
    }

    await pushSub.cancel();
  } finally {
    await client.close();
    stdout.writeln('Соединение закрыто.');
  }
}

Future<void> _interactiveLogin(MaxClient client, File tokenFile) async {
  stdout.write('Телефон в формате +79991234567: ');
  final phone = stdin.readLineSync()?.trim() ?? '';
  if (phone.isEmpty) {
    throw const MaxLoginFailed('phone is empty');
  }
  stdout.writeln('Запрашиваю SMS…');
  final verifyToken = await client.startAuthSms(phone);

  stdout.write('Код из SMS: ');
  final code = stdin.readLineSync()?.trim() ?? '';
  final r = await client.confirmSms(verifyToken, code);
  String token;
  if (r.authToken != null) {
    token = r.authToken!;
  } else {
    stdout.write('Пароль 2FA: ');
    stdin.echoMode = false;
    final pw = stdin.readLineSync()?.trim() ?? '';
    stdin.echoMode = true;
    stdout.writeln('');
    token = await client.confirm2fa(r.trackId!, pw);
  }
  tokenFile.writeAsStringSync(token);
  await client.login(token);
  stdout.writeln('Вход выполнен. Токен сохранён в ${tokenFile.absolute.path}.');
}

Future<void> _runCommand(MaxClient client, String line) async {
  final parts = line.split(RegExp(r'\s+'));
  final cmd = parts.first;
  switch (cmd) {
    case 'send':
      if (parts.length < 3) {
        stderr.writeln('Использование: send <chatId> <text...>');
        return;
      }
      final chatId = int.parse(parts[1]);
      final text = parts.skip(2).join(' ');
      final res = await client.sendMessage(chatId, text);
      stdout.writeln('OK: $res');
      break;
    case 'hist':
      if (parts.length < 2) {
        stderr.writeln('Использование: hist <chatId> [count]');
        return;
      }
      final chatId = int.parse(parts[1]);
      final count = parts.length >= 3 ? int.parse(parts[2]) : 20;
      final msgs = await client.chatHistory(chatId, count: count);
      for (final m in msgs) {
        stdout.writeln('[${m['id']}] ${m['sender']}: ${m['text']}');
      }
      break;
    case 'find':
      if (parts.length < 2) {
        stderr.writeln('Использование: find <phone>');
        return;
      }
      final c = await client.findContactByPhone(parts[1]);
      stdout.writeln('Контакт: $c');
      break;
    case 'me':
      final me = await client.currentProfile();
      stdout.writeln('Я: $me');
      break;
    default:
      stderr.writeln('Неизвестная команда: $cmd');
  }
}

void _printIncoming(IncomingMessage m) {
  stdout.writeln(
    '\n<-- chat=${m.chatId} from=${m.sender} '
    '${m.attaches.isNotEmpty ? "(+${m.attaches.length} attach) " : ""}'
    '${m.text}',
  );
  stdout.write('> ');
}
