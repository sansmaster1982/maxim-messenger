import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _initSqflitePlatform();
  await initializeDateFormatting('ru_RU', null);
  await initializeDateFormatting('ru', null);
  Intl.defaultLocale = 'ru_RU';
  runApp(const ProviderScope(child: MaximApp()));
}

/// На Windows/Linux/macOS — sqflite через FFI. На Android/iOS — нативный.
void _initSqflitePlatform() {
  if (kIsWeb) return;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
