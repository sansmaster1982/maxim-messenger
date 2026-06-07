import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../state/providers.dart';

/// Экран «Устройства и сессии»: список активных входов в аккаунт (op 96
/// SESSIONS_INFO) с возможностью завершить чужие (op 97 SESSIONS_CLOSE),
/// как в официальном приложении. Поля ответа извлекаются защитно — точный
/// формат уточняется по живому логу.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _sessions = const [];
  List<String> _rawKeys = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref.read(maxClientProvider).sessionsInfo();
      if (!mounted) return;
      setState(() {
        _sessions = _extractSessions(res);
        _rawKeys = res.keys.toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _extractSessions(Map<String, dynamic> res) {
    for (final k in const ['sessions', 'devices', 'items', 'list', 'result']) {
      final v = res[k];
      if (v is List) {
        return v
            .whereType<Map>()
            .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
            .toList();
      }
    }
    return const [];
  }

  int? _sessionId(Map<String, dynamic> s) {
    for (final k in const ['sessionId', 'id', 'session']) {
      final v = s[k];
      if (v is num) return v.toInt();
    }
    return null;
  }

  bool _isCurrent(Map<String, dynamic> s) {
    for (final k in const ['isCurrent', 'current', 'self', 'thisDevice']) {
      if (s[k] == true) return true;
    }
    return false;
  }

  String _title(Map<String, dynamic> s) {
    for (final k in const ['info', 'client', 'deviceName', 'name', 'appName']) {
      final v = s[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return 'Устройство';
  }

  String? _subtitle(Map<String, dynamic> s) {
    final parts = <String>[];
    final client = s['client'];
    // info уже в заголовке; в подзаголовок — клиент (если отличается), локация, время.
    if (client is String && client.isNotEmpty && client != _title(s)) {
      parts.add(client);
    }
    final loc = s['location'];
    if (loc is String && loc.isNotEmpty) parts.add(loc);
    for (final k in const [
      'time',
      'lastActivityTime',
      'lastActivity',
      'lastSeen',
      'updateTime',
    ]) {
      final v = s[k];
      if (v is num && v > 1000000000000) {
        parts.add(DateFormat('dd.MM.yyyy HH:mm').format(
          DateTime.fromMillisecondsSinceEpoch(v.toInt()),
        ));
        break;
      }
    }
    return parts.isEmpty ? null : parts.join('\n');
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Завершить'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Не удалось: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeAllOthers() async {
    if (!await _confirm(
      'Завершить все, кроме текущей?',
      'Все остальные устройства будут отключены от аккаунта. '
          'Текущее устройство останется в сети.',
    )) {
      return;
    }
    await _run(
      () => ref.read(maxClientProvider).closeSessions(exceptCurrent: true),
    );
  }

  Future<void> _closeOne(int id, String name) async {
    if (!await _confirm('Завершить сессию?', 'Устройство «$name» будет отключено.')) {
      return;
    }
    await _run(
      () => ref.read(maxClientProvider).closeSessions(sessionId: id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final others = _sessions.where((s) => !_isCurrent(s)).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Устройства и сессии'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    children: [
                      if (others > 0)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: FilledButton.tonalIcon(
                            onPressed: _busy ? null : _closeAllOthers,
                            icon: const Icon(Icons.logout),
                            style: FilledButton.styleFrom(
                              foregroundColor: scheme.error,
                            ),
                            label: const Text('Завершить все, кроме текущей'),
                          ),
                        ),
                      if (_sessions.isEmpty) _emptyView(),
                      ..._sessions.map(_sessionTile),
                    ],
                  ),
                ),
    );
  }

  Widget _sessionTile(Map<String, dynamic> s) {
    final current = _isCurrent(s);
    final id = _sessionId(s);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      isThreeLine: _subtitle(s)?.contains('\n') ?? false,
      leading: Icon(current ? Icons.smartphone : Icons.devices_other),
      title: Text(_title(s)),
      subtitle: _subtitle(s) == null ? null : Text(_subtitle(s)!),
      trailing: current
          ? Chip(
              label: const Text('текущая'),
              backgroundColor: scheme.primaryContainer,
              visualDensity: VisualDensity.compact,
            )
          : (id == null
              ? null
              : IconButton(
                  tooltip: 'Завершить',
                  icon: Icon(Icons.close, color: scheme.error),
                  onPressed: _busy ? null : () => _closeOne(id, _title(s)),
                )),
    );
  }

  Widget _emptyView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.devices_outlined, size: 48, color: Colors.black38),
          const SizedBox(height: 12),
          const Text(
            'Сессии не распознаны.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            'Сервер вернул поля: ${_rawKeys.join(', ')}',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text('Не удалось загрузить сессии:\n$_error',
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Повторить')),
          ],
        ),
      ),
    );
  }
}
