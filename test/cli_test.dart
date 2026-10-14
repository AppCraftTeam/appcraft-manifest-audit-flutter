import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

final String _executable = p.absolute('bin', 'appcraft_manifest_audit.dart');

ProcessResult _run(List<String> arguments, {String? from}) => Process.runSync(
      Platform.resolvedExecutable,
      <String>[_executable, ...arguments],
      workingDirectory: from,
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );

void main() {
  test('prints the version and exits 0', () {
    final result = _run(<String>['--version']);

    expect(result.exitCode, 0);
    expect((result.stdout as String).trim(), '0.0.1');
  });

  test('exits 64 in a directory that is not a project', () {
    final empty = Directory.systemTemp.createTempSync('manifest_audit_empty');
    addTearDown(() => empty.deleteSync(recursive: true));

    final result = _run(<String>['check'], from: empty.path);

    expect(result.exitCode, 64);
    expect(result.stderr, contains('pubspec.yaml not found'));
  });

  group('a project with build output', () {
    late Directory root;

    File baseline() =>
        File(p.join(root.path, 'android', 'manifest_audit.yaml'));

    File merged() => File(p.join(root.path, mergedManifestPath));

    setUp(() => root = createProject());

    tearDown(() => root.deleteSync(recursive: true));

    test('reports, writes a baseline, and then checks clean', () {
      expect(_run(<String>['report'], from: root.path).exitCode, 0);

      final written = _run(<String>['baseline'], from: root.path);
      expect(written.exitCode, 0);
      expect(baseline().existsSync(), isTrue);
      expect(baseline().readAsStringSync(), contains('  debug:\n'));

      final checked = _run(<String>['check'], from: root.path);
      expect(checked.exitCode, 0, reason: checked.stderr as String);
    });

    test('exits 1 when a permission appears that the baseline does not hold',
        () {
      _run(<String>['baseline'], from: root.path);

      merged().writeAsStringSync(merged().readAsStringSync().replaceFirst(
            '<uses-permission android:name="android.permission.INTERNET" />',
            '<uses-permission android:name="android.permission.INTERNET" />\n'
                '    <uses-permission android:name="com.google.android.gms.'
                'permission.AD_ID" />',
          ));

      final result = _run(<String>['check'], from: root.path);

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains('+ com.google.android.gms.permission.AD_ID'),
      );
    });

    test('exits 64 when the baseline is not there yet', () {
      final result = _run(<String>['check'], from: root.path);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('Baseline not found'));
    });

    test('exits 64 naming the baseline when it is not a baseline', () {
      writeFile(root, 'android/manifest_audit.yaml', 'variants: [\n');

      final result = _run(<String>['check'], from: root.path);

      expect(result.exitCode, 64);
      expect(
        result.stderr,
        contains(
            'android/manifest_audit.yaml: The baseline is not valid YAML.'),
      );
    });

    test('prints the diff and writes nothing under --dry-run', () {
      final result = _run(<String>['baseline', '--dry-run'], from: root.path);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('+ android.permission.WAKE_LOCK'));
      expect(baseline().existsSync(), isFalse);
    });

    test('refuses to write a baseline without a merged manifest', () {
      Directory(p.join(root.path, 'build', 'app', 'intermediates'))
          .deleteSync(recursive: true);

      final result = _run(<String>['baseline'], from: root.path);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('No merged manifest and no blame file'));
      expect(baseline().existsSync(), isFalse);
    });

    test('refuses to check against a report older than its inputs', () {
      _run(<String>['baseline'], from: root.path);
      File(p.join(root.path, 'pubspec.lock'))
          .setLastModifiedSync(DateTime.now().add(const Duration(days: 1)));

      final result = _run(<String>['check'], from: root.path);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('changed after'));
    });

    test('explains one permission and exits 64 on a name it does not have', () {
      final explained = _run(<String>['explain', 'WAKE_LOCK'], from: root.path);
      expect(explained.exitCode, 0);
      expect(
        explained.stdout,
        contains('com.google.firebase:firebase-messaging:24.1.0'),
      );

      final missing = _run(<String>['explain', 'NOTHING'], from: root.path);
      expect(missing.exitCode, 64);
      expect(missing.stderr, contains('Nothing matching "NOTHING"'));
    });

    test('keeps a variant the run did not audit in the baseline', () {
      _run(<String>['baseline'], from: root.path);
      baseline().writeAsStringSync(
        baseline().readAsStringSync().replaceFirst(
              'variants:\n',
              'variants:\n'
                  '  prod-release:\n'
                  '    permissions:\n'
                  '      android.permission.INTERNET:\n'
                  '        - app/src/main\n',
            ),
      );

      _run(<String>['baseline', '--variant', 'debug'], from: root.path);

      expect(baseline().readAsStringSync(), contains('  prod-release:\n'));

      // And a variant the baseline names with no report on disk is an error:
      // skipping it silently would let a release pipeline pass a check it
      // never ran.
      final result = _run(<String>['check'], from: root.path);
      expect(result.exitCode, 64);
      expect(
        result.stderr,
        contains('No merger report found for variant "prod-release".'),
      );
    });
  });
}
