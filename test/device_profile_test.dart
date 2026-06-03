import 'package:flutter_test/flutter_test.dart';
import 'package:maxim_messenger/core/constants.dart';
import 'package:maxim_messenger/data/max/device_profile.dart';

void main() {
  // Нужен для доступа к PlatformDispatcher (поле screen).
  TestWidgetsFlutterBinding.ensureInitialized();

  test('WEB userAgent остаётся минимальным (проверенная рабочая форма)',
      () async {
    final ua = await DeviceProfile.userAgent('WEB');
    expect(ua.keys.toList(), ['deviceType', 'locale', 'appVersion']);
    expect(ua['deviceType'], 'WEB');
    expect(ua['appVersion'], MaxProto.appVersion);
  });

  test('ANDROID userAgent — точный порядок полей официального клиента',
      () async {
    final ua = await DeviceProfile.userAgent('ANDROID');
    // Порядок ключей критичен: сервер MAX проверяет, что pushDeviceType идёт
    // вторым, а deviceType — в верхнем регистре (реверс koval01/openmax).
    expect(ua.keys.toList(), [
      'deviceType',
      'pushDeviceType',
      'appVersion',
      'arch',
      'buildNumber',
      'osVersion',
      'locale',
      'deviceLocale',
      'deviceName',
      'screen',
      'timezone',
    ]);
    expect(ua['deviceType'], 'ANDROID');
    expect(ua.keys.elementAt(1), 'pushDeviceType');
    expect(ua['pushDeviceType'], 'GCM');
    expect(ua['appVersion'], MaxProto.appVersion);
    expect(ua['buildNumber'], MaxProto.appBuild);
    expect(ua['locale'], MaxProto.locale);
    expect(ua['deviceLocale'], MaxProto.deviceLocale);
  });
}
