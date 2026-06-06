import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../data/local/database.dart';
import '../data/local/secure_storage.dart';
import '../data/max/device_profile.dart';
import '../data/max/max_client.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/chats_repository.dart';
import '../data/repositories/contacts_repository.dart';
import '../data/repositories/media_repository.dart';
import '../data/repositories/messages_repository.dart';
import '../data/repositories/upload_repository.dart';

final loggerProvider = Provider<Logger>((ref) {
  return Logger(printer: PrettyPrinter(methodCount: 0));
});

final secureStorageProvider = Provider<SecureStorage>((ref) {
  return SecureStorage();
});

final appDatabaseProvider = FutureProvider<AppDatabase>((ref) async {
  return AppDatabase.instance();
});

final maxClientProvider = Provider<MaxClient>((ref) {
  final logger = ref.watch(loggerProvider);
  final storage = ref.watch(secureStorageProvider);
  final client = MaxClient(
    logger: logger,
    // Стабильный deviceId на установку: убирает бан-сигнал «новое
    // устройство на каждый запуск» на одном номере.
    deviceIdLoader: storage.readOrCreateDeviceId,
    // Полный официально-выглядящий userAgent для ANDROID-входа.
    userAgentLoader: DeviceProfile.userAgent,
  );
  ref.onDispose(client.close);
  return client;
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    client: ref.watch(maxClientProvider),
    storage: ref.watch(secureStorageProvider),
    logger: ref.watch(loggerProvider),
  );
});

final uploadRepositoryProvider = FutureProvider<UploadRepository>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  final repo = UploadRepository(
    client: ref.watch(maxClientProvider),
    db: db,
    logger: ref.watch(loggerProvider),
  );
  ref.onDispose(repo.close);
  return repo;
});

final messagesRepositoryProvider = FutureProvider<MessagesRepository>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  final uploader = await ref.watch(uploadRepositoryProvider.future);
  final repo = MessagesRepository(
    client: ref.watch(maxClientProvider),
    db: db,
    storage: ref.watch(secureStorageProvider),
    uploader: uploader,
    logger: ref.watch(loggerProvider),
  );
  await repo.start();
  ref.onDispose(repo.stop);
  return repo;
});

final chatsRepositoryProvider = FutureProvider<ChatsRepository>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return ChatsRepository(
    client: ref.watch(maxClientProvider),
    db: db,
  );
});

final contactsRepositoryProvider = FutureProvider<ContactsRepository>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return ContactsRepository(
    client: ref.watch(maxClientProvider),
    db: db,
  );
});

final mediaRepositoryProvider = FutureProvider<MediaRepository>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return MediaRepository(
    client: ref.watch(maxClientProvider),
    db: db,
    logger: ref.watch(loggerProvider),
  );
});
