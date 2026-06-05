/// Извлечение человекочитаемого имени контакта из MAX-payload.
///
/// Сервер MAX часто отдаёт не плоское поле `name`, а список `names` —
/// объекты `{name, firstName, lastName, type}`, где `type`:
///   CUSTOM — имя, которое пользователь задал контакту в адресной книге;
///   ONEME  — имя из профиля самого контакта в MAX.
/// Старый код делал `names.toString()` и в UI попадал сырой дамп
/// `[{name: Я, firstName: Я, type: CUSTOM}, ...]`. Здесь выбираем
/// CUSTOM → ONEME → первый, внутри — `name` либо `firstName + lastName`.
String? displayContactName(Map<String, Object?> m) {
  final direct = m['name'];
  if (direct is String && direct.trim().isNotEmpty) return direct.trim();

  final names = m['names'];
  if (names is List && names.isNotEmpty) {
    Map<String, Object?>? custom;
    Map<String, Object?>? oneme;
    Map<String, Object?>? first;
    for (final e in names) {
      if (e is! Map) continue;
      final mm = e.map((k, v) => MapEntry(k.toString(), v));
      first ??= mm;
      switch (mm['type']?.toString()) {
        case 'CUSTOM':
          custom ??= mm;
        case 'ONEME':
          oneme ??= mm;
      }
    }
    final best = custom ?? oneme ?? first;
    if (best != null) {
      final n = best['name']?.toString().trim();
      if (n != null && n.isNotEmpty) return n;
      final fn = (best['firstName']?.toString() ?? '').trim();
      final ln = (best['lastName']?.toString() ?? '').trim();
      final full = [fn, ln].where((s) => s.isNotEmpty).join(' ');
      if (full.isNotEmpty) return full;
    }
  }
  return null;
}
