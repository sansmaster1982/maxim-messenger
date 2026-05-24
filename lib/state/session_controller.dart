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
      state = state.copyWith(error: e.toString());
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
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> submit2fa(String password) async {
    final repo = ref.read(authRepositoryProvider);
    state = state.copyWith(error: null);
    try {
      await repo.submit2fa(password);
      state = const SessionState(status: SessionStatus.signedIn);
    } catch (e) {
      state = state.copyWith(error: e.toString());
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
