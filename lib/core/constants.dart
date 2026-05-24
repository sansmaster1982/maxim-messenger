/// Константы протокола MAX и приложения.
class MaxProto {
  static const String host = 'api.oneme.ru';
  static const int port = 443;
  static const int protoVersion = 10;
  static const String appVersion = '26.11.0';
  static const String deviceType = 'ANDROID';
  static const String locale = 'ru';
}

/// Опкоды, известные на текущий момент.
/// Источник: реверс протокола в telega-to-max/max_client.py.
class MaxOp {
  static const int init = 6;
  static const int profile = 16;
  static const int authRequest = 17;
  static const int authConfirm = 18;
  static const int login = 19;
  static const int contactInfo = 32;
  static const int contactByPhone = 46;
  static const int chatInfo = 48;
  static const int chatHistory = 49;
  static const int sendMessage = 64;
  static const int typing = 65;
  static const int twoFa = 115;
}

class AppMeta {
  static const String name = 'Maxim';
  static const String dbName = 'maxim.db';
  static const String secureTokenKey = 'max_auth_token';
  static const String prefMyUserIdKey = 'my_max_user_id';
}
