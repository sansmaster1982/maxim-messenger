import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/auth_repository.dart';
import '../../state/session_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() op) async {
    setState(() => _busy = true);
    try {
      await op();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final ctrl = ref.read(sessionProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Вход в MAX')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (session.error != null) ...[
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      session.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (session.authFlow == AuthState.unauthenticated) ...[
                Text(
                  'Введи номер телефона в международном формате,\n'
                  'например +79991234567',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Телефон',
                    hintText: '+79991234567',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => ctrl.requestSms(_phoneCtrl.text.trim())),
                  child: _busy
                      ? const CircularProgressIndicator()
                      : const Text('Получить SMS-код'),
                ),
              ] else if (session.authFlow == AuthState.awaitingSms) ...[
                Text(
                  'Введи код из SMS, отправленный на ${session.phone ?? ''}',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _codeCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Код'),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => ctrl.submitSmsCode(_codeCtrl.text.trim()),
                        ),
                  child: _busy
                      ? const CircularProgressIndicator()
                      : const Text('Подтвердить'),
                ),
              ] else if (session.authFlow == AuthState.awaiting2fa) ...[
                const Text('Нужен пароль 2FA от MAX'),
                const SizedBox(height: 16),
                TextField(
                  controller: _pwCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Пароль 2FA'),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => ctrl.submit2fa(_pwCtrl.text)),
                  child: _busy
                      ? const CircularProgressIndicator()
                      : const Text('Войти'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
