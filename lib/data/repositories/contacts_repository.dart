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
}
