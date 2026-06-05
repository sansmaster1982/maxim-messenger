import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/auth_repository.dart';
import '../../state/session_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

enum _Mode { sms, token }

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _busy = false;
  bool _pwVisible = false;
  _Mode _mode = _Mode.sms;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _pwCtrl.dispose();
    _tokenCtrl.dispose();
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // переключатель способа входа
              SegmentedButton<_Mode>(
                segments: const [
                  ButtonSegment(value: _Mode.sms, label: Text('По SMS')),
                  ButtonSegment(value: _Mode.token, label: Text('По токену')),
                ],
                selected: {_mode},
                onSelectionChanged: _busy
                    ? null
                    : (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 20),

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

              if (_mode == _Mode.token)
                ..._tokenForm(ctrl)
              else
                ..._smsForm(session, ctrl),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────── вход по токену ───────────────
  List<Widget> _tokenForm(SessionController ctrl) {
    return [
      Text(
        'Вставьте auth-token аккаунта MAX (например из веб-версии '
        'web.max.ru: DevTools → Application → хранилище). SMS не нужен.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _tokenCtrl,
        minLines: 3,
        maxLines: 6,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'auth-token',
          hintText: 'Вставьте токен сюда...',
          alignLabelWithHint: true,
        ),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy
            ? null
            : () => _run(() => ctrl.loginWithToken(_tokenCtrl.text)),
        child: _busy
            ? const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Войти по токену'),
      ),
    ];
  }

  // ─────────────── вход по SMS ───────────────
  List<Widget> _smsForm(SessionState session, SessionController ctrl) {
    if (session.authFlow == AuthState.awaitingSms) {
      return [
        Text('Введи код из SMS, отправленный на ${session.phone ?? ''}'),
        const SizedBox(height: 16),
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Код'),
          onSubmitted: _busy
              ? null
              : (_) => _run(() => ctrl.submitSmsCode(_codeCtrl.text.trim())),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(() => ctrl.submitSmsCode(_codeCtrl.text.trim())),
          child: _busy
              ? const CircularProgressIndicator()
              : const Text('Подтвердить'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  _codeCtrl.clear();
                  _run(() => ctrl.resendSms());
                },
          child: const Text('Получить SMS заново'),
        ),
      ];
    }

    if (session.authFlow == AuthState.awaiting2fa) {
      return [
        const Text(
          'Введите пароль 2FA от вашего аккаунта MAX. '
          'Можно использовать любые символы (буквы, цифры).',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pwCtrl,
          obscureText: !_pwVisible,
          // TextInputType.text, а НЕ visiblePassword: на Samsung Keyboard
          // visiblePassword показывает цифровой пад, и буквы в пароль 2FA
          // ввести нельзя. text даёт полную QWERTY; скрытие — через obscureText.
          keyboardType: TextInputType.text,
          enableSuggestions: false,
          autocorrect: false,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Пароль 2FA',
            suffixIcon: IconButton(
              tooltip: _pwVisible ? 'Скрыть' : 'Показать',
              icon: Icon(
                _pwVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: () => setState(() => _pwVisible = !_pwVisible),
            ),
          ),
          onSubmitted: _busy
              ? null
              : (_) => _run(() => ctrl.submit2fa(_pwCtrl.text)),
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
      ];
    }

    // unauthenticated — ввод телефона
    return [
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
    ];
  }
}
