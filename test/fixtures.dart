import 'dart:io';

import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:path/path.dart' as p;

/// Recorded build output, trimmed and path-anonymised.
///
/// Three of the four sets under `test/reports` were taken from real builds. The
/// fourth, `implied`, was written by hand: no project available while this
/// package was written targets an SDK low enough to make the merger imply a
/// permission, and none uses an AGP old enough to prefix a node key with
/// `android:`. It is a guess at a format nobody here has seen the real version
/// of, and it should be read as one.
String fixture(String directory, String name) =>
    File(p.join('test', 'reports', directory, name)).readAsStringSync();

/// The `.flutter-plugins-dependencies` of the recorded project.
String get pluginsJson =>
    File(p.join('test', 'reports', 'flutter-plugins-dependencies.json'))
        .readAsStringSync();

/// Plugins of the recorded debug build whose own report is on disk.
const List<String> recordedPlugins = <String>[
  'camera_android_camerax',
  'firebase_core',
  'firebase_messaging',
];

/// The per-plugin decision tree logs of the recorded debug build.
Map<String, MergerReport> get pluginReports => <String, MergerReport>{
      for (final name in recordedPlugins)
        name: parseMergerReport(
          fixture('plugins', '$name-manifest-merger-debug-report.txt'),
        ),
    };

/// The attribution of a recorded variant, read with its merged manifest.
Attribution recordedAttribution(
  String directory,
  String variant,
  String manifest,
) =>
    attribute(
      variant: variant,
      report: parseMergerReport(
        fixture(directory, 'manifest-merger-$variant-report.txt'),
      ),
      nodes: readMergedManifest(fixture(directory, manifest)),
    );

/// The attribution of the recorded `prod-release`.
Attribution prodRelease() =>
    recordedAttribution('release', 'prod-release', 'AndroidManifest-prod.xml');

/// The packages the recorded project's `pubspec.yaml` names.
const Set<String> declared = <String>{
  'camera',
  'file_picker',
  'firebase_core',
  'firebase_messaging',
  'photo_manager',
  'vibration',
};

/// The `pubspec.yaml` of the recorded project.
const String projectPubspec = '''
name: demo_app

dependencies:
  camera: ^0.11.0
  file_picker: ^8.3.7
  firebase_core: ^3.13.0
  firebase_messaging: ^15.2.10
  photo_manager: ^3.6.4

dev_dependencies:
  vibration: ^3.1.3
''';

/// Merged manifest of the project [createProject] builds, relative to its
/// root.
const String mergedManifestPath = 'build/app/intermediates/merged_manifest/'
    'debug/processDebugMainManifest/AndroidManifest.xml';

/// Writes [content] to [relative] under [root], creating the directories.
void writeFile(Directory root, String relative, [String content = '']) {
  final file = File(p.join(root.path, relative.replaceAll('/', p.separator)));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

/// Sets the modification time of [relative] under [root].
void setModified(Directory root, String relative, DateTime when) =>
    File(p.join(root.path, relative.replaceAll('/', p.separator)))
        .setLastModifiedSync(when);

/// Builds a temp directory shaped like a Flutter project after a debug build.
///
/// Nothing here runs Gradle: the build output is the recorded fixtures, written
/// at the paths the discovery looks in.
Directory createProject() {
  final root = Directory.systemTemp.createTempSync('manifest_audit_project');

  writeFile(root, 'pubspec.yaml', projectPubspec);
  writeFile(root, 'pubspec.lock');
  writeFile(root, '.flutter-plugins-dependencies', pluginsJson);
  writeFile(root, 'android/app/src/main/AndroidManifest.xml', '<manifest />');
  writeFile(
    root,
    'build/app/outputs/logs/manifest-merger-debug-report.txt',
    fixture('debug', 'manifest-merger-debug-report.txt'),
  );
  writeFile(root, mergedManifestPath, fixture('debug', 'AndroidManifest.xml'));

  for (final plugin in recordedPlugins) {
    writeFile(
      root,
      'build/$plugin/outputs/logs/manifest-merger-debug-report.txt',
      fixture('plugins', '$plugin-manifest-merger-debug-report.txt'),
    );
  }

  // The report has to look newer than everything it was built from, or the
  // freshness guard is what the test would be measuring.
  for (final input in const <String>[
    'pubspec.lock',
    'android/app/src/main/AndroidManifest.xml',
  ]) {
    setModified(root, input, DateTime(2026));
  }

  return root;
}
