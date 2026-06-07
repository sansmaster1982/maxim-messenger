import 'dart:ui' as ui;

import 'package:device_info_plus/device_info_plus.dart';

import '../../core/constants.dart';

/// Сборка поля `userAgent` для SESSION_INIT (opcode 6).
///
/// Зачем: урезанный userAgent (`deviceType/locale/appVersion`) сам по себе
/// отличает клиент от официального. Реверс протокола (gist koval01,
/// openmax-server) показывает полный набор из 11 полей в строгом порядке:
/// `pushDeviceType` обязан идти ВТОРЫМ, `deviceType` — в верхнем регистре.
/// Сервер MAX не проверяет TLS/JA3, поэтому самосогласованный правдоподобный
/// userAgent безопасен и убирает дешёвый сигнал «не родной клиент».
///
/// Обогащаем только ANDROID-путь (там, где идут SMS-входы и баны). WEB и
/// прочее оставляем минимальными — этот путь (вход по веб-токену) уже
/// работает, а официальный WEB-userAgent не реверснут, ломать его смысла нет.
///
/// Порядок ключей сохраняется: литералы Map в Dart — LinkedHashMap, msgpack
/// сериализует в порядке вставки.
class DeviceProfile {
  const DeviceProfile._();

  static Future<Map<String, Object?>> userAgent(String deviceType) async {
    if (deviceType == 'IOS') {
      return _iosUserAgent();
    }
    if (deviceType != 'ANDROID') {
      return minimal(deviceType);
    }

    var arch = 'arm64-v8a';
    var osVersion = '34';
    var deviceName = 'Android';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.supportedAbis.isNotEmpty) {
        arch = info.supportedAbis.first;
      }
      osVersion = '${info.version.sdkInt}';
      final man = info.manufacturer.trim();
      final model = info.model.trim();
      final name = man.isEmpty ? model : '$man $model';
      if (name.trim().isNotEmpty) deviceName = name.trim();
    } catch (_) {
      // Нет нативного канала (desktop/CLI/тест) — остаются дефолты.
    }

    var screen = '1080x2340';
    try {
      final view = ui.PlatformDispatcher.instance.implicitView;
      final size = view?.physicalSize;
      if (size != null && size.width > 0 && size.height > 0) {
        screen = '${size.width.round()}x${size.height.round()}';
      }
    } catch (_) {}

    // Порядок строго как у официального клиента (pushDeviceType — 2-й).
    return {
      'deviceType': 'ANDROID',
      'pushDeviceType': 'GCM',
      'appVersion': MaxProto.appVersion,
      'arch': arch,
      'buildNumber': MaxProto.appBuild,
      'osVersion': osVersion,
      'locale': MaxProto.locale,
      'deviceLocale': MaxProto.deviceLocale,
      'deviceName': deviceName,
      'screen': screen,
      'timezone': _ianaTimezone(),
    };
  }

  /// Полный userAgent для iOS-сборки (deviceType=IOS). Тот же набор полей и
  /// порядок, что у ANDROID, но pushDeviceType=APNS и реальные поля iPhone.
  /// Имя устройства берём как модель (iPhone15,2), НЕ пользовательское имя
  /// (то — PII). ВНИМАНИЕ: appVersion/buildNumber здесь пока от Android-сборки;
  /// для полной маскировки подставь версию ОФИЦИАЛЬНОГО iOS-приложения MAX.
  static Future<Map<String, Object?>> _iosUserAgent() async {
    var osVersion = '17.0';
    var deviceName = 'iPhone';
    try {
      final info = await DeviceInfoPlugin().iosInfo;
      if (info.systemVersion.isNotEmpty) osVersion = info.systemVersion;
      final model = info.utsname.machine.trim();
      deviceName = model.isNotEmpty ? model : info.model;
    } catch (_) {
      // Нет нативного канала (не iOS/тест) — дефолты.
    }

    var screen = '1170x2532';
    try {
      final view = ui.PlatformDispatcher.instance.implicitView;
      final size = view?.physicalSize;
      if (size != null && size.width > 0 && size.height > 0) {
        screen = '${size.width.round()}x${size.height.round()}';
      }
    } catch (_) {}

    return {
      'deviceType': 'IOS',
      'pushDeviceType': 'APNS',
      'appVersion': MaxProto.appVersion,
      'arch': 'arm64',
      'buildNumber': MaxProto.appBuild,
      'osVersion': osVersion,
      'locale': MaxProto.locale,
      'deviceLocale': MaxProto.deviceLocale,
      'deviceName': deviceName,
      'screen': screen,
      'timezone': _ianaTimezone(),
    };
  }

  /// Проверенный рабочим python-клиентом минимум — для WEB и fallback.
  static Map<String, Object?> minimal(String deviceType) => {
    'deviceType': deviceType,
    'locale': MaxProto.locale,
    'appVersion': MaxProto.appVersion,
  };

  /// Best-effort IANA-таймзона по смещению. Сервер таймзону жёстко не
  /// валидирует (у реальных клиентов она разная); важна правдоподобность.
  static String _ianaTimezone() {
    final off = DateTime.now().timeZoneOffset.inHours;
    switch (off) {
      case 2:
        return 'Europe/Kaliningrad';
      case 3:
        return 'Europe/Moscow';
      case 4:
        return 'Asia/Tbilisi';
      case 5:
        return 'Asia/Yekaterinburg';
      case 6:
        return 'Asia/Omsk';
      case 7:
        return 'Asia/Krasnoyarsk';
      case 8:
        return 'Asia/Irkutsk';
      case 9:
        return 'Asia/Yakutsk';
      case 10:
        return 'Asia/Vladivostok';
      case 11:
        return 'Asia/Magadan';
      case 12:
        return 'Asia/Kamchatka';
      default:
        return 'Europe/Moscow';
    }
  }
}
