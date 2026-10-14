import 'dart:io';

import 'package:path/path.dart' as p;

import 'merger_report.dart';

/// The files one variant's audit reads.
final class VariantOutputs {
  /// Creates a set of outputs.
  const VariantOutputs({
    required this.variant,
    required this.report,
    required this.module,
    this.mergedManifest,
    this.blameFile,
  });

  /// Variant name, lower-case and hyphen-joined.
  final String variant;

  /// Decision tree log of the variant.
  final File report;

  /// Directory of the module's build outputs the report was found under.
  final Directory module;

  /// Merged manifest of the same build, absent when it is not on disk.
  final File? mergedManifest;

  /// Blame file of the same build, the fallback when [mergedManifest] is
  /// absent.
  final File? blameFile;

  /// The file the nodes of the app are read from, if any.
  File? get manifestSource => mergedManifest ?? blameFile;
}

/// Finds the Android build outputs of a project.
///
/// Nothing here composes a path from a template. Flutter moves the build
/// directory, AGP 7 and AGP 8 write different layouts, and both generations
/// routinely sit on disk at once — so the tool globs a bounded set of roots and
/// picks, preferring the newest file when two layouts answer the same question.
final class BuildOutputs {
  /// Creates a discovery rooted at the project directory.
  const BuildOutputs({
    required this.root,
    this.build,
  });

  /// Project root, the directory holding `pubspec.yaml`.
  final String root;

  /// Configured root of the module's build outputs, relative to [root].
  ///
  /// Unset means the two conventional places are searched instead.
  final String? build;

  /// Roots searched when [build] is unset.
  ///
  /// Flutter's `android/build.gradle` redirects the build directory out of
  /// `android/`, so the app module writes to `build/app`. Some teams delete
  /// those lines, which puts it back at `android/app/build`.
  static const List<String> defaultRoots = <String>[
    'build/app',
    'android/app/build',
  ];

  /// Directories the reports are looked for in.
  List<Directory> get moduleRoots {
    final build = this.build;
    final relative = build == null ? defaultRoots : <String>[build];

    return <Directory>[
      for (final entry in relative)
        Directory(p.normalize(p.join(root, entry.replaceAll(r'\', '/')))),
    ];
  }

  /// Outputs of every variant with a report on disk, sorted by variant name.
  ///
  /// A variant found under two module roots keeps the newer report: one of the
  /// two is a leftover of a build that no longer exists.
  List<VariantOutputs> discover() {
    final found = <String, VariantOutputs>{};

    for (final module in moduleRoots) {
      final logs = Directory(p.join(module.path, 'outputs', 'logs'));
      if (!logs.existsSync()) continue;

      for (final entity in logs.listSync(followLinks: false)) {
        if (entity is! File) continue;

        final match = _reportName.firstMatch(p.basename(entity.path));
        if (match == null) continue;

        final variant = normalizeVariant(match.group(1)!);
        final previous = found[variant];
        if (previous != null && _isNewer(previous.report, entity)) continue;

        found[variant] = VariantOutputs(
          variant: variant,
          report: entity,
          module: module,
          mergedManifest: _mergedManifestOf(module, variant),
          blameFile: _blameFileOf(module, variant),
        );
      }
    }

    final variants = found.keys.toList()..sort();

    return <VariantOutputs>[
      for (final variant in variants) found[variant]!,
    ];
  }

  /// The merged manifest of [variant] under [module], if one is on disk.
  ///
  /// Four of them exist per variant and in practice they agree about the
  /// permissions. The one written by the same task as the report is preferred,
  /// because the two are consistent by construction; the app-link settings
  /// manifest that shares its directory is preferred last.
  File? _mergedManifestOf(Directory module, String variant) {
    final candidates = <(int, int, File)>[];

    final intermediates = Directory(p.join(module.path, 'intermediates'));
    if (!intermediates.existsSync()) return null;

    for (final artifact in intermediates.listSync(followLinks: false)) {
      if (artifact is! Directory) continue;

      final rank = _artifactRank[p.basename(artifact.path)];
      if (rank == null) continue;

      for (final directory in artifact.listSync(followLinks: false)) {
        if (directory is! Directory) continue;
        if (normalizeVariant(p.basename(directory.path)) != variant) continue;

        for (final file in _manifestsUnder(directory)) {
          candidates.add((rank, _taskRank(directory, file), file));
        }
      }
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final byArtifact = a.$1.compareTo(b.$1);
      if (byArtifact != 0) return byArtifact;

      final byTask = a.$2.compareTo(b.$2);
      if (byTask != 0) return byTask;

      return b.$3.statSync().modified.compareTo(a.$3.statSync().modified);
    });

    return candidates.first.$3;
  }

  /// The blame file of [variant] under [module], if one is on disk.
  ///
  /// Its path mixes the camel-case variant name, the task name and the
  /// dash-joined base name in one string, so it is globbed rather than
  /// composed. Two AGP generations write it at two depths and both can be
  /// there; the newest wins.
  File? _blameFileOf(Directory module, String variant) {
    final blame = Directory(
      p.join(module.path, 'intermediates', 'manifest_merge_blame_file'),
    );
    if (!blame.existsSync()) return null;

    File? newest;
    for (final directory in blame.listSync(followLinks: false)) {
      if (directory is! Directory) continue;
      if (normalizeVariant(p.basename(directory.path)) != variant) continue;

      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!_blameName.hasMatch(p.basename(entity.path))) continue;

        if (newest == null || _isNewer(entity, newest)) newest = entity;
      }
    }

    return newest;
  }

  /// Inputs that changed after [outputs] were written.
  ///
  /// Gradle skips the manifest task when it considers it up to date, so a
  /// report can outlive the change that invalidates it. Adding a plugin and
  /// running `check` without a build must not produce a confident wrong answer.
  ///
  /// It cannot catch a plugin whose own manifest changed inside the pub cache
  /// at the same version.
  List<String> staleInputs(VariantOutputs outputs) {
    if (!outputs.report.existsSync()) return const <String>[];

    final written = outputs.report.statSync().modified;
    final inputs = <String>[
      'pubspec.lock',
      p.join('android', 'app', 'build.gradle'),
      p.join('android', 'app', 'build.gradle.kts'),
      ..._sourceSetManifests(outputs.variant),
    ];

    return <String>[
      for (final input in inputs)
        if (File(p.join(root, input)).existsSync())
          if (File(p.join(root, input)).statSync().modified.isAfter(written))
            input.replaceAll(r'\', '/'),
    ];
  }

  /// Manifests of the app's source sets [variant] is built from, sorted.
  ///
  /// A source set is named after a flavour, a build type or a combination of
  /// them — `stagingEu`, `release`, `prodRelease` — so every one whose name is
  /// a run of the variant's segments counts, along with `main`.
  List<String> _sourceSetManifests(String variant) {
    final sources = Directory(p.join(root, 'android', 'app', 'src'));
    if (!sources.existsSync()) return const <String>[];

    final names = <String>[
      for (final entity in sources.listSync(followLinks: false))
        if (entity is Directory) p.basename(entity.path),
    ]..sort();

    return <String>[
      for (final name in names)
        if (normalizeVariant(name) case final sourceSet
            when sourceSet == 'main' || '-$variant-'.contains('-$sourceSet-'))
          p.join('android', 'app', 'src', name, 'AndroidManifest.xml'),
    ];
  }

  /// Build directories of the plugins, keyed by pub package name.
  ///
  /// The paths of the `[:name]` lines of [reportPaths] are followed as the
  /// report gives them: a flavoured app references the plugin's unflavoured
  /// build, so composing the path from the app's variant name finds nothing.
  /// A path that leads nowhere, as it does once the project has moved since
  /// the build, falls back to the subproject's name under the build root.
  Map<String, Directory> pluginBuilds({
    required Map<String, String> reportPaths,
  }) {
    final builds = <String, Directory>{};

    for (final entry in reportPaths.entries) {
      final directory = _buildDirectoryOf(entry.value);
      if (directory != null && directory.existsSync()) {
        builds[entry.key] = directory;
      }
    }

    for (final module in moduleRoots) {
      final buildRoot = module.parent;
      if (!buildRoot.existsSync()) continue;

      for (final name in reportPaths.keys) {
        if (builds.containsKey(name)) continue;

        final directory = Directory(p.join(buildRoot.path, name));
        if (directory.existsSync()) builds[name] = directory;
      }
    }

    return builds;
  }

  /// The newest decision tree log under [build], preferring the one of
  /// [variant].
  static File? pluginReportOf(Directory build, String? variant) {
    final logs = Directory(p.join(build.path, 'outputs', 'logs'));
    if (!logs.existsSync()) return null;

    File? newest;
    for (final entity in logs.listSync(followLinks: false)) {
      if (entity is! File) continue;

      final match = _reportName.firstMatch(p.basename(entity.path));
      if (match == null) continue;

      if (variant != null && normalizeVariant(match.group(1)!) == variant) {
        return entity;
      }
      if (newest == null || _isNewer(entity, newest)) newest = entity;
    }

    return newest;
  }

  /// The module build directory a merged-manifest path of the report sits in.
  ///
  /// `…\build\appsflyer_sdk\intermediates\merged_manifest\debug\…` gives
  /// `…\build\appsflyer_sdk`.
  static Directory? _buildDirectoryOf(String manifestPath) {
    final segments = pathSegments(manifestPath);
    final index = segments.lastIndexOf('intermediates');
    if (index <= 0) return null;

    return Directory(segments.sublist(0, index).join(p.separator));
  }

  /// The plugin variant a merged-manifest path of the report names.
  ///
  /// The variant does not carry across the hop: an app built as `betaDebug`
  /// references the plugin's `debug` build.
  static String? pluginVariantOf(String manifestPath) {
    final segments = pathSegments(manifestPath);

    for (final artifact in _artifactRank.keys) {
      final index = segments.lastIndexOf(artifact);
      if (index != -1 && index + 1 < segments.length) {
        return normalizeVariant(segments[index + 1]);
      }
    }

    return null;
  }

  static List<File> _manifestsUnder(Directory directory) => <File>[
        for (final entity in directory.listSync(recursive: true))
          if (entity is File &&
              p.basename(entity.path) == 'AndroidManifest.xml')
            entity,
      ];

  /// How much a manifest written by a given task is worth.
  ///
  /// The task that writes the report writes the main manifest, so that one is
  /// read first. An AGP 7 layout has no task segment at all and comes next. The
  /// app-link settings manifest shares the directory of the main one and is not
  /// the packaged manifest of anything, so it comes last.
  static int _taskRank(Directory variantDirectory, File manifest) {
    final task =
        p.relative(p.dirname(manifest.path), from: variantDirectory.path);
    if (task == '.') return 1;
    if (task.contains('MainManifest')) return 0;
    if (task.contains('ForPackage')) return 2;
    if (task.contains('AppLinkSettings')) return 4;

    return 3;
  }

  static bool _isNewer(File a, File b) =>
      a.statSync().modified.isAfter(b.statSync().modified);

  static const Map<String, int> _artifactRank = <String, int>{
    'merged_manifest': 0,
    'merged_manifests': 1,
    'packaged_manifests': 2,
  };

  static final RegExp _reportName =
      RegExp(r'^manifest-merger-(?!blame-)(.+)-report\.txt$');
  static final RegExp _blameName =
      RegExp(r'^manifest-merger-blame-.*-report\.txt$');
}

/// The name of a variant as the report file spells it: lower-case,
/// hyphen-joined, flavour first.
///
/// The Gradle camel-case form is accepted and normalised, because that is what
/// people type: `prodRelease` and `prod-release` are the same variant, and the
/// intermediates directories use the first while the logs use the second.
String normalizeVariant(String name) => name
    .replaceAllMapped(_camelBoundary, (match) => '${match[0]}-')
    .toLowerCase();

/// The last character before a camel-case word, `qaUSRelease` split before
/// `US` and before `Release`.
final RegExp _camelBoundary = RegExp('[a-z0-9](?=[A-Z])|[A-Z](?=[A-Z][a-z])');
