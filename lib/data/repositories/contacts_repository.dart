import 'dart:async';
import 'dart:math';

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

  /// Жёсткий потолок на число резолвов номеров за один импорт. Массовое
  /// перечисление справочника через op=46 — главный поведенческий бан-сигнал
  /// (по данным антифрода MAX спам/скрейпинг — причина №1 блокировок). Так
  /// что импорт намеренно «человеческий»: мало и медленно.
  static const int bulkLookupCap = 50;

  /// Bulk-поиск контактов по списку номеров. Anti-ban профиль: строго
  /// последовательно (не пачками), по одному запросу раз в ~1.1–1.8с с
  /// джиттером, не более [bulkLookupCap] номеров за раз. Возвращает
  /// (найдено, проверено, пропущено-сверх-лимита).
  Future<({int found, int checked, int skipped})> bulkLookupByPhones(
    List<String> phones, {
    void Function(int done, int total)? onProgress,
  }) async {
    final cleaned = <String>{};
    for (final p in phones) {
      final n = _normalizePhone(p);
      if (n != null) cleaned.add(n);
    }
    final all = cleaned.toList();
    final list = all.length > bulkLookupCap
        ? all.sublist(0, bulkLookupCap)
        : all;
    final skipped = all.length - list.length;
    final total = list.length;
    var done = 0;
    var found = 0;
    final rng = Random();
    onProgress?.call(done, total);

    for (final phone in list) {
      if (await _lookupOne(phone)) found++;
      done++;
      onProgress?.call(done, total);
      if (done < total) {
        // 1.1–1.8с между запросами: темп живого человека, не сканера.
        final ms = 1100 + rng.nextInt(700);
        await Future<void>.delayed(Duration(milliseconds: ms));
      }
    }
    return (found: found, checked: total, skipped: skipped);
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
  /// тех, кто там зарегистрирован. Возвращает (найдено, проверено, пропущено).
  Future<({int found, int checked, int skipped})> importFromAddressBook({
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
      return (found: 0, checked: 0, skipped: 0);
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
