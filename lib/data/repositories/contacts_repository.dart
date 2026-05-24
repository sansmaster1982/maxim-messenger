import 'dart:async';

import 'package:flutter_contacts/flutter_contacts.dart';

import '../local/database.dart';
import '../max/max_client.dart';
import '../max/models/contact.dart';

class ContactsRepository {
  ContactsRepository({required this.client, required this.db});

  final MaxClient client;
  final AppDatabase db;

  Future<List<MaxContact>> listLocal() => db.contacts();
  Future<MaxContact?> get(int id) => db.contact(id);

  /// Найти контакт по телефону, сохранить локально, вернуть.
  /// Бросает [StateError] если сервер ничего не нашёл.
  Future<MaxContact> findByPhone(String phone) async {
    final raw = await client.findContactByPhone(phone);
    final id = (raw['id'] as num?)?.toInt();
    if (id == null) {
      throw StateError('Контакт по номеру $phone не найден');
    }
    final c = MaxContact(
      id: id,
      name: raw['name']?.toString(),
      phone: raw['phone']?.toString() ?? phone,
    );
    await db.upsertContact(c);
    return c;
  }

  Future<void> refresh(List<int> ids) async {
    if (ids.isEmpty) return;
    final info = await client.contactInfo(ids);
    final arr = info['contacts'] ?? info['items'];
    if (arr is! List) return;
    for (final m in arr) {
      if (m is! Map) continue;
      final mm = m.map((k, v) => MapEntry(k.toString(), v));
      final id = (mm['id'] as num?)?.toInt();
      if (id == null) continue;
      await db.upsertContact(MaxContact(
        id: id,
        name: mm['name']?.toString() ?? mm['names']?.toString(),
        phone: mm['phone']?.toString(),
        avatarUrl: mm['avatar']?.toString() ?? mm['photo']?.toString(),
      ));
    }
  }

  Future<void> remove(int contactId) async {
    await db.deleteContact(contactId);
  }

  Future<List<MaxContact>> search(String query) async {
    return db.searchContacts(query);
  }

  /// Bulk-поиск контактов по списку номеров. Параллельность ограничена
  /// батчами по 5; между батчами небольшая пауза, чтобы не давить сервер.
  Future<int> bulkLookupByPhones(
    List<String> phones, {
    void Function(int done, int total)? onProgress,
  }) async {
    final cleaned = <String>{};
    for (final p in phones) {
      final n = _normalizePhone(p);
      if (n != null) cleaned.add(n);
    }
    final list = cleaned.toList();
    final total = list.length;
    var done = 0;
    var found = 0;
    onProgress?.call(done, total);

    const batchSize = 5;
    for (var i = 0; i < list.length; i += batchSize) {
      final end = (i + batchSize <= list.length) ? i + batchSize : list.length;
      final batch = list.sublist(i, end);
      final results = await Future.wait(
        batch.map((p) => _lookupOne(p)),
      );
      for (final r in results) {
        if (r) found++;
      }
      done += batch.length;
      onProgress?.call(done, total);
      if (end < list.length) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    return found;
  }

  Future<bool> _lookupOne(String phone) async {
    try {
      final raw = await client.findContactByPhone(phone);
      final id = (raw['id'] as num?)?.toInt();
      if (id == null) return false;
      await db.upsertContact(MaxContact(
        id: id,
        name: raw['name']?.toString(),
        phone: raw['phone']?.toString() ?? phone,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Запросить разрешение, прочитать адресную книгу, найти в MAX
  /// тех, кто там зарегистрирован. Возвращает число найденных.
  Future<int> importFromAddressBook({
    void Function(int done, int total)? onProgress,
  }) async {
    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!granted) {
      throw StateError('Нет разрешения на чтение контактов');
    }
    final contacts = await FlutterContacts.getContacts(
      withProperties: true,
    );
    final phones = <String>{};
    for (final c in contacts) {
      for (final ph in c.phones) {
        final n = _normalizePhone(ph.number);
        if (n != null) phones.add(n);
      }
    }
    if (phones.isEmpty) {
      onProgress?.call(0, 0);
      return 0;
    }
    return bulkLookupByPhones(phones.toList(), onProgress: onProgress);
  }

  /// Оставить только цифры; если был ведущий `+`, сохранить его.
  static String? _normalizePhone(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final hasPlus = trimmed.startsWith('+');
    final digits = trimmed.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    return hasPlus ? '+$digits' : digits;
  }
}
