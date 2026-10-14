import 'dart:io';

import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

const String _report = '''
debug — 6 permission(s), 3 component(s)

Permissions the app declares itself (2):
  android.permission.INTERNET                          app/src/debug, app/src/main
  android.permission.READ_EXTERNAL_STORAGE             app/src/main

Permissions injected by libraries (4):
  android.permission.ACCESS_ADSERVICES_AD_ID           androidx.privacysandbox.ads:ads-adservices
  android.permission.RECORD_AUDIO                      camera_android_camerax (via camera)
  android.permission.VIBRATE                           vibration
  android.permission.WAKE_LOCK                         com.google.firebase:firebase-messaging

In the manifest with no node in the report (1):
  android.permission.POST_NOTIFICATIONS                unattributed

Components: 3, from 4 libraries. Run "explain" for one of them.
''';

const String _explainWakeLock = '''
android.permission.WAKE_LOCK — debug

  Maven artifacts (1):
    com.google.firebase:firebase-messaging:24.1.0
  Which package pulled them in is not in the report; "gradlew :app:dependencies" in android/ shows it.

  Not declared in android/app/src. To drop it:
    <uses-permission android:name="android.permission.WAKE_LOCK"
        tools:node="remove" />
  as a direct child of <manifest> in android/app/src/main/AndroidManifest.xml.

''';

void main() {
  late Directory root;
  late ManifestAuditor auditor;

  VariantAudit audit() =>
      auditor.audit(auditor.select(const <String>[]).single);

  setUp(() {
    root = createProject();
    auditor = ManifestAuditor(
      root: root.path,
      config: const ManifestAuditConfig(),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('discovers the report and the merged manifest of the build', () {
    final variant = auditor.select(const <String>[]).single;

    expect(variant.variant, 'debug');
    expect(variant.mergedManifest, isNotNull);
    expect(audit().staleInputs, isEmpty);
  });

  test('renders the report of a whole project', () {
    expect(renderReport(audit()), _report);
  });

  test('explains a permission through the artifact that carried it', () {
    expect(
        renderExplain(<VariantAudit>[audit()], 'WAKE_LOCK'), _explainWakeLock);
  });

  test('explains a component merged from a plugin and from an artifact', () {
    final explained = renderExplain(
      <VariantAudit>[audit()],
      'provider#androidx.startup.InitializationProvider',
    );

    expect(
      explained,
      contains('  firebase_core 3.13.0                                 '
          'direct dependency\n'
          '    android/src/main/AndroidManifest.xml:4\n'
          '  Maven artifacts (1):\n'
          '    androidx.startup:startup-runtime:1.1.1\n'),
    );
  });

  test('warns when an input changed after the report was written', () {
    File(p.join(root.path, 'pubspec.lock'))
        .setLastModifiedSync(DateTime.now().add(const Duration(days: 1)));

    expect(
      renderReport(audit()),
      startsWith('Warning: pubspec.lock changed after '
          'build/app/outputs/logs/manifest-merger-debug-report.txt was '
          'written.'),
    );
  });

  test('says a run without a manifest is a run with less information', () {
    Directory(p.join(root.path, 'build', 'app', 'intermediates'))
        .deleteSync(recursive: true);

    final degraded = audit();
    expect(degraded.hasManifest, isFalse);
    expect(
      renderReport(degraded),
      startsWith('Neither the merged manifest nor the blame file is on disk'),
    );
  });

  test('falls back to the blame file when the merged manifest is gone', () {
    Directory(p.join(root.path, 'build', 'app', 'intermediates'))
        .deleteSync(recursive: true);
    writeFile(
      root,
      'build/app/intermediates/manifest_merge_blame_file/debug/'
      'processDebugManifest/manifest-merger-blame-debug-report.txt',
      fixture('removed', 'manifest-merger-blame-release-report.txt'),
    );

    final rescued = audit();
    expect(rescued.hasManifest, isTrue);
    expect(rescued.attribution.degraded, isFalse);
  });

  test('refuses a variant the build output does not hold', () {
    expect(
      () => auditor.select(const <String>['prod-release']),
      throwsA(isA<BuildOutputException>().having(
        (e) => e.message,
        'message',
        allOf(
          contains('No merger report found for variant "prod-release".'),
          contains('Found reports for: debug'),
          contains('flutter build apk --release --flavor prod'),
        ),
      )),
    );
  });

  test('names the flavour to build as Gradle spells it', () {
    writeFile(
        root,
        'build/app/outputs/logs/manifest-merger-qaUS-debug-report.txt',
        fixture('debug', 'manifest-merger-debug-report.txt'));

    Matcher flavour(String spelling) => throwsA(isA<BuildOutputException>()
        .having((e) => e.message, 'message', contains('--flavor $spelling')));

    expect(
        () => auditor.select(const <String>['qa-us-release']), flavour('qaUS'));
    expect(() => auditor.select(const <String>['stagingEURelease']),
        flavour('stagingEU'));
    expect(() => auditor.select(const <String>['prod-eu-release']),
        flavour('prodEu'));
  });

  test('accepts the camel-case variant name people type', () {
    writeFile(
        root,
        'build/app/outputs/logs/manifest-merger-prod-release-report.txt',
        fixture('release', 'manifest-merger-prod-release-report.txt'));

    expect(
      auditor.select(const <String>['prodRelease']).single.variant,
      'prod-release',
    );
  });

  test('stops when the report is there and nothing in it parses', () {
    writeFile(
      root,
      'build/app/outputs/logs/manifest-merger-debug-report.txt',
      '<html>\n<body>not a merger report</body>\n</html>\n',
    );

    expect(
      () => audit(),
      throwsA(isA<BuildOutputException>().having(
        (e) => e.message,
        'message',
        allOf(
          contains('the format has changed'),
          contains('--merged-manifest'),
        ),
      )),
    );
  });

  test('stops when there is no build output at all', () {
    Directory(p.join(root.path, 'build')).deleteSync(recursive: true);

    expect(
      () => auditor.select(const <String>[]),
      throwsA(isA<BuildOutputException>().having(
        (e) => e.message,
        'message',
        contains('build/app/outputs/logs'),
      )),
    );
  });

  test('takes the report named on the command line', () {
    final named = ManifestAuditor(
      root: root.path,
      config: const ManifestAuditConfig(),
      reportOverride: 'build/app/outputs/logs/manifest-merger-debug-report.txt',
      mergedManifestOverride: mergedManifestPath,
    );

    expect(renderReport(named.audit(named.select(const <String>[]).single)),
        _report);
  });
}
