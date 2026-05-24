import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/max/max_client.dart';
import 'providers.dart';

/// Стрим состояния транспортного соединения. UI подписывается на него,
/// чтобы рисовать баннер «нет связи»/«переподключаемся».
///
/// `connectionState` в [MaxClient] — broadcast-стрим, который эмитит только
/// изменения. Чтобы первый билд получил текущее значение, склеиваем его с
/// синхронным значением [MaxClient.currentState].
final connectionStateProvider = StreamProvider<MaxConnectionState>((ref) {
  final client = ref.watch(maxClientProvider);
  final controller = StreamController<MaxConnectionState>();
  controller.add(client.currentState);
  final sub = client.connectionState.listen(
    controller.add,
    onError: controller.addError,
  );
  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});
