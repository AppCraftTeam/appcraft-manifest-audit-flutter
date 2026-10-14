import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:test/test.dart';

void main() {
  test('configures nothing by default, because the default is discovery', () {
    final config = ManifestAuditConfig.fromPubspec('name: app\n');

    expect(config.baseline, 'android/manifest_audit.yaml');
    expect(config.build, isNull);
    expect(config.variants, isEmpty);
    expect(config.ignore, isEmpty);
  });

  test('reads the section', () {
    final config = ManifestAuditConfig.fromPubspec('''
name: app

appcraft_manifest_audit:
  baseline: android/permissions.yaml
  build: build/app
  variants:
    - prod-release
  ignore:
    - android.permission.INTERNET
''');

    expect(config.baseline, 'android/permissions.yaml');
    expect(config.build, 'build/app');
    expect(config.variants, <String>['prod-release']);
    expect(config.ignore, <String>['android.permission.INTERNET']);
  });

  test('refuses a path that leaves the project root', () {
    expect(
      () => const ManifestAuditConfig(baseline: '../shared/baseline.yaml')
          .validate(),
      throwsA(isA<ManifestAuditConfigException>()),
    );
    expect(
      () => const ManifestAuditConfig(build: '/var/build').validate(),
      throwsA(isA<ManifestAuditConfigException>()),
    );
  });

  test('refuses a key carrying the wrong type', () {
    expect(
      () => ManifestAuditConfig.fromPubspec(
        'appcraft_manifest_audit:\n  baseline: 3\n',
      ),
      throwsA(isA<ManifestAuditConfigException>()),
    );
    expect(
      () => ManifestAuditConfig.fromPubspec(
        'appcraft_manifest_audit:\n  variants: prod-release\n',
      ),
      throwsA(isA<ManifestAuditConfigException>()),
    );
  });

  test('refuses a pubspec that is not YAML', () {
    expect(
      () => ManifestAuditConfig.fromPubspec('name: [app\n'),
      throwsA(isA<ManifestAuditConfigException>().having(
        (e) => e.message,
        'message',
        startsWith('pubspec.yaml is not valid YAML.'),
      )),
    );
  });

  test('reads the packages the developer wrote down', () {
    expect(
      declaredDependencies('''
name: app

dependencies:
  camera: ^0.11.0
  flutter:
    sdk: flutter

dev_dependencies:
  vibration: ^3.1.3
'''),
      <String>{'camera', 'flutter', 'vibration'},
    );
  });

  group('the plugins file', () {
    const String json = r'''
{
  "plugins": {
    "android": [
      {
        "name": "camera_android_camerax",
        "path": "C:\\Pub\\Cache\\hosted\\pub.dev\\camera_android_camerax-0.6.19\\",
        "native_build": true,
        "dev_dependency": false
      },
      {
        "name": "camera_web",
        "path": "C:\\Pub\\Cache\\hosted\\pub.dev\\camera_web-0.3.5\\",
        "native_build": false,
        "dev_dependency": false
      },
      {
        "name": "vibration",
        "path": "C:\\Pub\\Cache\\hosted\\pub.dev\\vibration-3.1.3\\",
        "native_build": true,
        "dev_dependency": true
      }
    ]
  },
  "dependencyGraph": [
    {"name": "camera", "dependencies": ["camera_android_camerax", "camera_web"]},
    {"name": "camera_android_camerax", "dependencies": []},
    {"name": "vibration", "dependencies": []}
  ]
}
''';

    test('drops the Dart-only implementations, which are never owners', () {
      expect(
        PluginIndex.parse(json).byName.keys,
        <String>['camera_android_camerax', 'vibration'],
      );
    });

    test('reads the version off the pub cache directory', () {
      expect(
          PluginIndex.parse(json)['camera_android_camerax']!.version, '0.6.19');
      expect(PluginIndex.parse(json)['vibration']!.devDependency, isTrue);
    });

    test('names the package a pubspec would name instead', () {
      expect(
        PluginIndex.parse(json)['camera_android_camerax']!.via,
        <String>['camera'],
      );
    });

    test('leaves a declared package alone', () {
      expect(
        PluginIndex.parse(json, declared: const <String>{
          'camera_android_camerax',
        })['camera_android_camerax']!
            .via,
        isEmpty,
      );
    });
  });
}
