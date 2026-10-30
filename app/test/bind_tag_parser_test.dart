import 'package:flutter_test/flutter_test.dart';

import 'package:bkl_app/core/nfc/nfc_reader.dart';

void main() {
  group('BindTagParser', () {
    test('解析合法的绑定 URI', () {
      final tag = BindTagParser.fromUri(
        Uri.parse(
            'https://bkl.example.com/bind?d=BKL-2026-000123&c=7qk2m5xj4tzp6rwn'),
      );
      expect(tag, isNotNull);
      expect(tag!.deviceId, 'BKL-2026-000123');
      // 声明码统一转成大写
      expect(tag.claimCode, '7QK2M5XJ4TZP6RWN');
    });

    test('路径不是 /bind 时拒绝', () {
      expect(
        BindTagParser.fromUri(Uri.parse(
            'https://bkl.example.com/other?d=BKL-2026-000123&c=7QK2M5XJ4TZP6RWN')),
        isNull,
      );
    });

    test('缺少参数时拒绝', () {
      expect(
          BindTagParser.fromUri(
              Uri.parse('https://bkl.example.com/bind?d=BKL-2026-000123')),
          isNull);
      expect(
          BindTagParser.fromUri(
              Uri.parse('https://bkl.example.com/bind?c=7QK2M5XJ4TZP6RWN')),
          isNull);
    });

    test('声明码长度不对时拒绝', () {
      expect(
        BindTagParser.fromUri(Uri.parse(
            'https://bkl.example.com/bind?d=BKL-2026-000123&c=SHORT')),
        isNull,
      );
    });

    test('声明码含非法 Base32 字符时拒绝', () {
      // 0/1/8/9 不在 Base32 字母表内，避免把易混字符写进产线标签
      expect(
        BindTagParser.fromUri(Uri.parse(
            'https://bkl.example.com/bind?d=BKL-2026-000123&c=0189ABCDEFGHJKLM')),
        isNull,
      );
    });

    test('设备编号过短时拒绝', () {
      expect(
        BindTagParser.fromUri(
            Uri.parse('https://bkl.example.com/bind?d=a&c=7QK2M5XJ4TZP6RWN')),
        isNull,
      );
    });

    test('fromText 容忍首尾空白', () {
      final tag = BindTagParser.fromText(
        '  https://bkl.example.com/bind?d=BKL-2026-000123&c=7QK2M5XJ4TZP6RWN  ',
      );
      expect(tag?.deviceId, 'BKL-2026-000123');
    });

    test('toString 不泄露声明码', () {
      const tag =
          BindTag(deviceId: 'BKL-2026-000123', claimCode: '7QK2M5XJ4TZP6RWN');
      expect(tag.toString().contains('7QK2M5XJ4TZP6RWN'), isFalse);
    });
  });
}
