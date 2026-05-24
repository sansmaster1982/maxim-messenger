import 'package:equatable/equatable.dart';

class MaxContact extends Equatable {
  final int id;
  final String? name;
  final String? phone;
  final String? avatarUrl;

  const MaxContact({
    required this.id,
    this.name,
    this.phone,
    this.avatarUrl,
  });

  factory MaxContact.fromMap(Map<String, dynamic> m) {
    return MaxContact(
      id: (m['id'] as num).toInt(),
      name: m['name']?.toString(),
      phone: m['phone']?.toString(),
      avatarUrl: m['avatarUrl']?.toString() ?? m['photo']?.toString(),
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'phone': phone,
    'avatar_url': avatarUrl,
  };

  factory MaxContact.fromDbRow(Map<String, Object?> r) => MaxContact(
    id: r['id'] as int,
    name: r['name'] as String?,
    phone: r['phone'] as String?,
    avatarUrl: r['avatar_url'] as String?,
  );

  @override
  List<Object?> get props => [id, name, phone, avatarUrl];
}
