import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/max/models/contact.dart';
import '../data/repositories/contacts_repository.dart';
import 'providers.dart';

/// Прогресс импорта адресной книги. [total] = 0 означает «не запущено».
class ImportProgress {
  const ImportProgress({
    required this.done,
    required this.total,
    this.running = false,
    this.found,
    this.error,
  });

  final int done;
  final int total;
  final bool running;
  final int? found;
  final String? error;

  static const idle = ImportProgress(done: 0, total: 0);

  ImportProgress copyWith({
    int? done,
    int? total,
    bool? running,
    int? found,
    String? error,
  }) {
    return ImportProgress(
      done: done ?? this.done,
      total: total ?? this.total,
      running: running ?? this.running,
      found: found ?? this.found,
      error: error ?? this.error,
    );
  }
}

class ContactsListController extends AsyncNotifier<List<MaxContact>> {
  ContactsRepository? _repo;
  List<MaxContact> _all = const [];
  String _query = '';

  @override
  Future<List<MaxContact>> build() async {
    _repo = await ref.watch(contactsRepositoryProvider.future);
    _all = await _repo!.listLocal();
    return _applyFilter(_all, _query);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    try {
      final repo = await _ensureRepo();
      _all = await repo.listLocal();
      state = AsyncData(_applyFilter(_all, _query));
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> removeContact(int id) async {
    final repo = await _ensureRepo();
    await repo.remove(id);
    _all = _all.where((c) => c.id != id).toList();
    state = AsyncData(_applyFilter(_all, _query));
  }

  /// Возвращает (найдено, проверено, пропущено-сверх-лимита). Прогресс
  /// пробрасывается callback'ом, итог — через возвращаемое значение.
  Future<({int found, int checked, int skipped})> importFromAddressBook({
    void Function(ImportProgress progress)? onProgress,
  }) async {
    final repo = await _ensureRepo();
    onProgress?.call(ImportProgress.idle.copyWith(running: true));
    try {
      final result = await repo.importFromAddressBook(
        onProgress: (done, total) {
          onProgress?.call(ImportProgress(
            done: done,
            total: total,
            running: true,
          ));
        },
      );
      _all = await repo.listLocal();
      state = AsyncData(_applyFilter(_all, _query));
      onProgress?.call(ImportProgress(
        done: 0,
        total: 0,
        running: false,
        found: result.found,
      ));
      return result;
    } catch (e) {
      onProgress?.call(ImportProgress(
        done: 0,
        total: 0,
        running: false,
        error: e.toString(),
      ));
      rethrow;
    }
  }

  void search(String query) {
    _query = query;
    state = AsyncData(_applyFilter(_all, _query));
  }

  Future<ContactsRepository> _ensureRepo() async {
    final cached = _repo;
    if (cached != null) return cached;
    final repo = await ref.read(contactsRepositoryProvider.future);
    _repo = repo;
    return repo;
  }

  static List<MaxContact> _applyFilter(List<MaxContact> all, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((c) {
      final n = (c.name ?? '').toLowerCase();
      final p = (c.phone ?? '').toLowerCase();
      return n.contains(q) || p.contains(q);
    }).toList();
  }
}

final contactsListProvider =
    AsyncNotifierProvider<ContactsListController, List<MaxContact>>(
  ContactsListController.new,
);

final contactsSearchQueryProvider = StateProvider<String>((_) => '');
