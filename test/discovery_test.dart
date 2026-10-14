import 'dart:io';

import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late Directory root;

  BuildOutputs outputs({String? build}) =>
      BuildOutputs(root: root.path, build: build);

  setUp(() => root = Directory.systemTemp.createTempSync('manifest_audit'));

  tearDown(() => root.deleteSync(recursive: true));

  test('finds every variant with a report and names it as the file does', () {
    writeFile(
        root, 'build/app/outputs/logs/manifest-merger-prod-release-report.txt');
    writeFile(
        root, 'build/app/outputs/logs/manifest-merger-beta-debug-report.txt');
    writeFile(root, 'build/app/outputs/logs/manifest-merger-debug-report.txt');

    expect(
      outputs().discover().map((entry) => entry.variant),
      <String>['beta-debug', 'debug', 'prod-release'],
    );
  });

  test('leaves the blame file out of the variant list', () {
    writeFile(root, 'build/app/outputs/logs/manifest-merger-debug-report.txt');
    writeFile(
        root, 'build/app/outputs/logs/manifest-merger-blame-debug-report.txt');

    expect(outputs().discover(), hasLength(1));
  });

  test('falls back to the build directory of a project that does not redirect',
      () {
    writeFile(root,
        'android/app/build/outputs/logs/manifest-merger-release-report.txt');

    expect(
      outputs().discover().single.variant,
      'release',
    );
  });

  test('reads the AGP 8 merged manifest of the task that wrote the report', () {
    writeFile(
        root, 'build/app/outputs/logs/manifest-merger-prod-release-report.txt');
    writeFile(
        root,
        'build/app/intermediates/merged_manifest/prodRelease/'
        'processProdReleaseMainManifest/AndroidManifest.xml');
    writeFile(
        root,
        'build/app/intermediates/merged_manifest/prodRelease/'
        'outputProdReleaseAppLinkSettings/AndroidManifest.xml');
    writeFile(
        root,
        'build/app/intermediates/packaged_manifests/prodRelease/'
        'processProdReleaseManifestForPackage/AndroidManifest.xml');

    expect(
      outputs().discover().single.mergedManifest!.path,
      contains('processProdReleaseMainManifest'),
    );
  });

  test('reads the AGP 7 merged manifest, which has no task segment', () {
    writeFile(root, 'build/app/outputs/logs/manifest-merger-debug-report.txt');
    writeFile(root,
        'build/app/intermediates/merged_manifest/debug/AndroidManifest.xml');

    expect(
      outputs().discover().single.mergedManifest,
      isNotNull,
    );
  });

  test('prefers the newest when two AGP layouts sit on disk at once', () {
    writeFile(root, 'build/app/outputs/logs/manifest-merger-debug-report.txt');
    writeFile(
        root,
        'build/app/intermediates/manifest_merge_blame_file/debug/'
        'manifest-merger-blame-debug-report.txt');
    writeFile(
        root,
        'build/app/intermediates/manifest_merge_blame_file/debug/'
        'processDebugManifest/manifest-merger-blame-debug-report.txt');

    setModified(
      root,
      'build/app/intermediates/manifest_merge_blame_file/debug/'
      'manifest-merger-blame-debug-report.txt',
      DateTime(2020),
    );

    expect(
      outputs().discover().single.blameFile!.path,
      contains('processDebugManifest'),
    );
  });

  test('takes the configured build root over the conventional ones', () {
    writeFile(root, 'build/app/outputs/logs/manifest-merger-debug-report.txt');
    writeFile(
        root, 'out/module/outputs/logs/manifest-merger-release-report.txt');

    expect(
      outputs(build: 'out/module').discover().map((entry) => entry.variant),
      <String>['release'],
    );
  });

  group('freshness', () {
    setUp(() {
      writeFile(root, 'pubspec.lock');
      writeFile(root, 'android/app/src/main/AndroidManifest.xml');
      writeFile(root, 'android/app/src/release/AndroidManifest.xml');
      writeFile(root,
          'build/app/outputs/logs/manifest-merger-prod-release-report.txt');

      setModified(root, 'pubspec.lock', DateTime(2026, 1, 1));
      setModified(root, 'android/app/src/main/AndroidManifest.xml',
          DateTime(2026, 1, 1));
      setModified(root, 'android/app/src/release/AndroidManifest.xml',
          DateTime(2026, 1, 1));
      setModified(
        root,
        'build/app/outputs/logs/manifest-merger-prod-release-report.txt',
        DateTime(2026, 1, 2),
      );
    });

    test('says nothing when the report is newer than every input', () {
      expect(outputs().staleInputs(outputs().discover().single), isEmpty);
    });

    test('names a lockfile changed after the build', () {
      setModified(root, 'pubspec.lock', DateTime(2026, 1, 3));

      expect(
        outputs().staleInputs(outputs().discover().single),
        <String>['pubspec.lock'],
      );
    });

    test('names the source-set manifest of the variant', () {
      setModified(root, 'android/app/src/release/AndroidManifest.xml',
          DateTime(2026, 1, 3));

      expect(
        outputs().staleInputs(outputs().discover().single),
        <String>['android/app/src/release/AndroidManifest.xml'],
      );
    });

    test('names a combined source set and the module build script', () {
      writeFile(root, 'android/app/build.gradle.kts');
      writeFile(root, 'android/app/src/prodRelease/AndroidManifest.xml');
      writeFile(root, 'android/app/src/debug/AndroidManifest.xml');

      expect(
        outputs().staleInputs(outputs().discover().single),
        <String>[
          'android/app/build.gradle.kts',
          'android/app/src/prodRelease/AndroidManifest.xml',
        ],
      );
    });
  });

  group('variant names', () {
    test('normalises the Gradle camel-case form people type', () {
      expect(normalizeVariant('prodRelease'), 'prod-release');
      expect(normalizeVariant('prod-release'), 'prod-release');
      expect(normalizeVariant('debug'), 'debug');
      expect(normalizeVariant('prodEuRelease'), 'prod-eu-release');
    });

    test('splits a flavour written in capitals as the report file does', () {
      expect(normalizeVariant('qaUSRelease'), 'qa-us-release');
      expect(normalizeVariant('qaUS-release'), 'qa-us-release');
    });
  });

  group('the hop to a plugin build', () {
    test('reads the plugin variant off the path the report gives', () {
      expect(
        BuildOutputs.pluginVariantOf(
          r'C:\Projects\demo\build\appsflyer_sdk\intermediates\merged_manifest'
          r'\debug\processDebugManifest\AndroidManifest.xml',
        ),
        'debug',
      );
    });

    test('follows the path the report gives, then the build root', () {
      writeFile(
          root,
          'out/firebase_core/outputs/logs/'
          'manifest-merger-debug-report.txt');
      writeFile(
          root,
          'build/firebase_messaging/outputs/logs/'
          'manifest-merger-debug-report.txt');

      final builds = outputs().pluginBuilds(
        reportPaths: <String, String>{
          'firebase_core': p.join(
              root.path,
              'out',
              'firebase_core',
              'intermediates',
              'merged_manifest',
              'debug',
              'AndroidManifest.xml'),
          'firebase_messaging': '/elsewhere/build/firebase_messaging/'
              'intermediates/merged_manifest/debug/AndroidManifest.xml',
          'not_built': '/elsewhere/build/not_built/'
              'intermediates/merged_manifest/debug/AndroidManifest.xml',
        },
      );

      expect(builds.keys, <String>['firebase_core', 'firebase_messaging']);
      expect(builds['firebase_core']!.path, contains('out'));
      expect(
        BuildOutputs.pluginReportOf(builds['firebase_messaging']!, 'debug'),
        isNotNull,
      );
    });
  });
}
