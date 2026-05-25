import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session_controller.dart';
import 'login_screen.dart';
import 'main_shell.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    switch (session.status) {
      case SessionStatus.loading:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case SessionStatus.signedOut:
        return const LoginScreen();
      case SessionStatus.signedIn:
        return const MainShell();
    }
  }
}
