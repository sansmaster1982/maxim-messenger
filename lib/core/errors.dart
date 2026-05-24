class MaxError implements Exception {
  final String message;
  const MaxError(this.message);
  @override
  String toString() => 'MaxError: $message';
}

class MaxLoginFailed extends MaxError {
  const MaxLoginFailed(super.message);
  @override
  String toString() => 'MaxLoginFailed: $message';
}

class MaxNotConnected extends MaxError {
  const MaxNotConnected(super.message);
  @override
  String toString() => 'MaxNotConnected: $message';
}

class MaxTimeout extends MaxError {
  const MaxTimeout(super.message);
  @override
  String toString() => 'MaxTimeout: $message';
}
