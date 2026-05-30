import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/auth_repository.dart';
import 'providers.dart';

enum SessionStatus { loading, signedOut, signedIn }

class SessionState {
  final SessionStatus status;
  final AuthState authFlow;
  final String? phone;
  final String? error;

  const SessionState({
    required this.status,
    this.authFlow = AuthState.unauthenticated,
    this.phone,
    this.error,
  });

  SessionState copyWith({
    SessionStatus? status,
    AuthState? authFlow,
    String? phone,
    String? error,
  }) {
    return SessionState(
      status: status ?? this.status,
      authFlow: authFlow ?? this.authFlow,
      phone: phone ?? this.phone,
      error: error,
    );
  }
}

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() {
    Future.microtask(_bootstrap);
    return const SessionState(status: SessionStatus.loading);
  }

  Future<void> _bootstrap() async {
    final repo = ref.read(authRepositoryProvider);
    // Мёртвый токен (FAIL_LOGIN_TOKEN) во время reconnect → разлогин.
    repo.client.onAuthInvalid = () async {
      await repo.storage.wipe();
      state = const SessionState(
        status: SessionStatus.signedOut,
        error: 'Сессия истекла, войдите снова',
      );
    };
    final ok = await repo.tryRestoreSession();
    state = SessionState(
      status: ok ? SessionStatus.signedIn : SessionStatus.signedOut,
    );
  }

  Future<void> requestSms(String phone) async {
    final repo = ref.read(authRepositoryProvider);
    state = state.copyWith(error: null);
    try {
      await repo.requestSms(phone);
      state = state.copyWith(
        phone: phone,
        authFlow: AuthState.awaitingSms,
      );
    } catch (e) {
      state = state.copyWith(error: _humanError(e));
    }
  }

  Future<void> submitSmsCode(String code) async {
    final repo = ref.read(authRepositoryProvider);
    state = state.copyWith(error: null);
    try {
      final next = await repo.submitSmsCode(code);
      if (next == AuthState.authenticated) {
        state = SessionState(status: SessionStatus.signedIn);
      } else {
        state = state.copyWith(authFlow: AuthState.awaiting2fa);
      }
    } catch (e) {
      // Если verify-token использован/истёк — сбросим состояние SMS,
      // UI покажет ошибку и предложит запросить новый код.
      repo.resetSmsState();
      state = state.copyWith(error: _humanError(e));
    }
  }

  /// Повторно отправить SMS-код на тот же номер. Используется после
  /// ошибки подтверждения (истёкший verify-token).
  Future<void> resendSms() async {
    final phone = state.phone;
    if (phone == null || phone.isEmpty) return;
    await requestSms(phone);
  }

  String _humanError(Object e) {
    final s = e.toString();
    // обрезаем тип исключения для красоты
    final idx = s.indexOf(': ');
    return idx >= 0 ? s.substring(idx + 2) : s;
  }

  Future<void> submit2fa(String password) async {
    final repo = ref.read(authRepositoryProvider);
    state = state.copyWith(error: null);
    try {
      await repo.submit2fa(password);
      state = const SessionState(status: SessionStatus.signedIn);
    } catch (e) {
      state = state.copyWith(error: _humanError(e));
    }
  }

  /// Вход по готовому auth-token (вкладка «По токену» в LoginScreen).
  Future<void> loginWithToken(String token) async {
    final repo = ref.read(authRepositoryProvider);
    state = state.copyWith(error: null);
    final t = token.trim();
    if (t.isEmpty) {
      state = state.copyWith(error: 'Вставьте токен');
      return;
    }
    try {
      await repo.loginWithToken(t);
      state = const SessionState(status: SessionStatus.signedIn);
    } catch (e) {
      state = state.copyWith(error: _humanError(e));
    }
  }

  Future<void> logout() async {
    final repo = ref.read(authRepositoryProvider);
    await repo.logout();
    state = const SessionState(status: SessionStatus.signedOut);
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
