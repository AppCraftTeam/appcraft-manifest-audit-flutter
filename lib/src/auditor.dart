import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'attribution.dart';
import 'config.dart';
import 'discovery.dart';
import 'merged_manifest.dart';
import 'merger_report.dart';
import 'plugins.dart';

/// Thrown when the build output cannot answer the question.
///
/// Every one of these is exit 64: the tool was asked about something that is
/// not on disk, or is on disk in a shape it does not recognise.
final class BuildOutputException implements Exception {
  /// Creates an exception carrying a message meant for the user.
  const BuildOutputException(this.message);

  /// What is missing or unusable, and what to do about it.
  final String message;

  @override
  String toString() => message;
}

/// One variant's audit, with what the run had to work with.
final class VariantAudit {
  /// Creates an audit.
  const VariantAudit({
    required this.attribution,
    required this.report,
    required this.staleInputs,
    this.manifestSource,
  });

  /// The answer.
  final Attribution attribution;

  /// Decision tree log the answer was read from, relative to the project root.
  final String report;

  /// Inputs that changed after the report was written, relative to the project
  /// root.
  ///
  /// `report` warns about them and `check` refuses: a report that outlived the
  /// change that invalidates it gives a confident wrong answer.
  final List<String> staleInputs;

  /// File the app's own nodes were read from, absent on a degraded run.
  final String? manifestSource;

  /// Whether the run had the merged manifest or the blame file.
  bool get hasManifest => manifestSource != null;
}

/// Reads the Android build outputs of a project and attributes them.
final class ManifestAuditor {
  /// Creates an auditor for a project at [root].
  ManifestAuditor({
    required this.root,
    required this.config,
    this.reportOverride,
    this.mergedManifestOverride,
  });

  /// Project root, the directory holding `pubspec.yaml`.
  final String root;

  /// Settings of the audit.
  final ManifestAuditConfig config;

  /// Report named on the command line, bypassing the discovery.
  final String? reportOverride;

  /// Merged manifest named on the command line, bypassing the discovery.
  final String? mergedManifestOverride;

  /// Discovery of the build outputs.
  BuildOutputs get outputs => BuildOutputs(root: root, build: config.build);

  /// Every variant with a report on disk, or the one named by `--report`.
  ///
  /// Throws a [BuildOutputException] when `--report` names a file whose variant
  /// cannot be read off its name and no `--variant` was given.
  List<VariantOutputs> discover({List<String> requested = const <String>[]}) {
    final override = reportOverride;
    if (override == null) return outputs.discover();

    final file = File(p.join(root, override));
    if (!file.existsSync()) {
      throw BuildOutputException('Report not found: $override');
    }

    return <VariantOutputs>[_overridden(file, requested)];
  }

  /// The variants to audit, given what the command line asked for.
  ///
  /// With nothing requested and nothing configured, every variant on disk is
  /// audited. A requested variant with no report on disk is an error: silently
  /// skipping it would let a release pipeline pass a check it never ran.
  List<VariantOutputs> select(List<String> requested) {
    final found = discover(requested: requested);
    final typed = requested.isEmpty ? config.variants : requested;
    final wanted = <String>[
      for (final variant in typed) normalizeVariant(variant),
    ];

    if (found.isEmpty) throw BuildOutputException(_nothingFound(wanted));

    if (wanted.isEmpty) return found;

    final byName = <String, VariantOutputs>{
      for (final entry in found) entry.variant: entry,
    };
    final missing = <String>[
      for (final variant in wanted)
        if (!byName.containsKey(variant)) variant,
    ];
    if (missing.isNotEmpty) {
      throw BuildOutputException(_missing(missing, found, typed));
    }

    return <VariantOutputs>[
      for (final variant in wanted) byName[variant]!,
    ];
  }

  /// Audits one variant.
  ///
  /// Throws a [BuildOutputException] when the report is on disk and nothing in
  /// it parses, which means the format changed.
  VariantAudit audit(VariantOutputs variant) {
    final report = parseMergerReport(variant.report.readAsStringSync());
    if (report.nodes.isEmpty) {
      throw BuildOutputException(_unrecognised(variant.report));
    }

    final source = _manifestSource(variant);
    final nodes = source == null ? null : _readNodes(source);
    final plugins = _plugins();

    return VariantAudit(
      attribution: attribute(
        variant: variant.variant,
        report: report,
        nodes: nodes,
        plugins: plugins,
        pluginReports: _pluginReports(report),
        ignore: config.ignore,
      ),
      report: _relative(variant.report.path),
      staleInputs: outputs.staleInputs(variant),
      manifestSource: source == null ? null : _relative(source.path),
    );
  }

  /// Reads `.flutter-plugins-dependencies`, which is what attributing a
  /// `[:name]` to a pub package consumes.
  PluginIndex _plugins() {
    final file = File(p.join(root, '.flutter-plugins-dependencies'));
    if (!file.existsSync()) return PluginIndex.empty;

    final pubspec = File(p.join(root, 'pubspec.yaml'));

    try {
      return PluginIndex.parse(
        file.readAsStringSync(),
        declared: pubspec.existsSync()
            ? declaredDependencies(pubspec.readAsStringSync())
            : const <String>{},
      );
    } on FormatException catch (e) {
      throw BuildOutputException(
        'Could not read .flutter-plugins-dependencies: ${e.message}\n'
        'Run "flutter pub get" to rewrite it.',
      );
    }
  }

  /// The per-plugin decision tree logs, keyed by pub package name.
  Map<String, MergerReport> _pluginReports(MergerReport report) {
    final paths = <String, String>{};
    for (final node in report.nodes) {
      final lines = <Provenance>[
        ...node.provenance,
        for (final attribute in node.attributes) ...attribute.provenance,
      ];

      for (final line in lines) {
        if (line.owner case SubprojectOwner(:final name)) {
          paths.putIfAbsent(name, () => line.path);
        }
      }
    }

    final builds = outputs.pluginBuilds(reportPaths: paths);

    final reports = <String, MergerReport>{};
    for (final entry in builds.entries) {
      final path = paths[entry.key];
      final file = BuildOutputs.pluginReportOf(
        entry.value,
        path == null ? null : BuildOutputs.pluginVariantOf(path),
      );
      if (file == null) continue;

      reports[entry.key] = parseMergerReport(file.readAsStringSync());
    }

    return reports;
  }

  File? _manifestSource(VariantOutputs variant) {
    final override = mergedManifestOverride;
    if (override == null) return variant.manifestSource;

    final file = File(p.join(root, override));
    if (!file.existsSync()) {
      throw BuildOutputException('Merged manifest not found: $override');
    }

    return file;
  }

  ManifestNodes _readNodes(File file) {
    final content = file.readAsStringSync();
    final isBlame = p.basename(file.path).startsWith('manifest-merger-blame-');

    try {
      return isBlame ? readBlameFile(content) : readMergedManifest(content);
    } on XmlException catch (e) {
      throw BuildOutputException(
        'Could not read ${_relative(file.path)} as a manifest: ${e.message}',
      );
    }
  }

  VariantOutputs _overridden(File file, List<String> requested) {
    final match = _reportName.firstMatch(p.basename(file.path));
    final variant = match != null
        ? normalizeVariant(match.group(1)!)
        : requested.length == 1
            ? normalizeVariant(requested.single)
            : null;

    if (variant == null) {
      throw BuildOutputException(
        'Cannot tell which variant ${p.basename(file.path)} describes.\n'
        'Name it with a single --variant.',
      );
    }

    // The module root is `<module>/outputs/logs/<file>`; a report kept
    // elsewhere leaves the discovery of the merged manifest with nothing to
    // work with, which is what --merged-manifest is for.
    final module = p.basename(file.parent.path) == 'logs' &&
            p.basename(file.parent.parent.path) == 'outputs'
        ? file.parent.parent.parent
        : file.parent;

    final discovery = BuildOutputs(
      root: root,
      build: p.relative(module.path, from: root),
    );
    final found = <String, VariantOutputs>{
      for (final entry in discovery.discover()) entry.variant: entry,
    };

    return VariantOutputs(
      variant: variant,
      report: file,
      module: module,
      mergedManifest: found[variant]?.mergedManifest,
      blameFile: found[variant]?.blameFile,
    );
  }

  String _relative(String path) =>
      p.relative(path, from: root).replaceAll(r'\', '/');

  String _nothingFound(List<String> wanted) {
    final looked = outputs.moduleRoots
        .map((directory) => '${_relative(directory.path)}/outputs/logs')
        .join(', ');
    final subject =
        wanted.isEmpty ? 'No merger report found.' : _noReportFor(wanted);

    return '$subject\n'
        'Looked in: $looked\n\n'
        'Build the variant first:\n'
        '  flutter build apk --release';
  }

  String _noReportFor(List<String> wanted) => wanted.length == 1
      ? 'No merger report found for variant "${wanted.single}".'
      : 'No merger report found for variants ${wanted.map((v) => '"$v"').join(', ')}.';

  String _missing(
    List<String> missing,
    List<VariantOutputs> found,
    List<String> typed,
  ) {
    final spellings = <String>[
      ...typed,
      for (final entry in found)
        if (_reportName.firstMatch(p.basename(entry.report.path))
            case final match?)
          match.group(1)!,
    ];

    return '${_noReportFor(missing)}\n'
        'Found reports for: ${found.map((entry) => entry.variant).join(', ')}\n\n'
        'Build the variant first:\n'
        '  ${_buildCommand(missing.first, spellings)}';
  }

  /// The command that produces the report of [variant].
  ///
  /// The last segment is the build type and everything before it is the
  /// flavour, which is how the merger spells the base name. [spellings] are
  /// variant names that kept their case.
  static String _buildCommand(String variant, List<String> spellings) {
    final segments = variant.split('-');
    final type = segments.removeLast();
    final flavour = segments.join('-');

    return <String>[
      'flutter build apk',
      if (type == 'release') '--release' else '--$type',
      if (flavour.isNotEmpty)
        '--flavor ${_flavourSpelling(flavour, spellings)}',
    ].join(' ');
  }

  /// [flavour], normalised, as Gradle spells it.
  ///
  /// Normalising loses the case, so the spelling is taken from a variant name
  /// that kept it — one typed in camel case, or a report on disk — and is
  /// otherwise rebuilt in camel case, which is how Gradle joins flavour names.
  static String _flavourSpelling(String flavour, List<String> spellings) {
    for (final spelling in spellings) {
      final type = normalizeVariant(spelling).split('-').last;
      final head = spelling.substring(0, spelling.length - type.length);
      final candidate =
          head.endsWith('-') ? head.substring(0, head.length - 1) : head;

      if (!candidate.contains('-') && normalizeVariant(candidate) == flavour) {
        return candidate;
      }
    }

    final words = flavour.split('-');

    return <String>[
      words.first,
      for (final word in words.skip(1))
        '${word[0].toUpperCase()}${word.substring(1)}',
    ].join();
  }

  String _unrecognised(File report) {
    final head =
        report.readAsLinesSync().take(5).map((line) => '  $line').join('\n');

    return 'Nothing in ${_relative(report.path)} parses as a merging decision '
        'tree, so the format has changed. Its first lines are:\n'
        '$head\n\n'
        'Until this package catches up, "--merged-manifest <path>" still gives '
        'the permission list without the attribution.';
  }

  static final RegExp _reportName =
      RegExp(r'^manifest-merger-(?!blame-)(.+)-report\.txt$');
}
