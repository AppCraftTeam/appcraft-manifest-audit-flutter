import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Thrown when the configuration cannot be used as it is.
final class ManifestAuditConfigException implements Exception {
  /// Creates an exception carrying a message meant for the user.
  const ManifestAuditConfigException(this.message);

  /// What is wrong with the configuration.
  final String message;

  @override
  String toString() => message;
}

/// Settings of the audit, read from the `appcraft_manifest_audit` section of
/// `pubspec.yaml`.
///
/// Every default is discovery, so a normal Flutter project configures nothing.
final class ManifestAuditConfig {
  /// Creates a configuration, falling back to the defaults.
  const ManifestAuditConfig({
    this.baseline = defaultBaseline,
    this.build,
    this.variants = const <String>[],
    this.ignore = const <String>[],
  });

  /// Reads the configuration from the content of a `pubspec.yaml`.
  ///
  /// A missing section and missing keys fall back to the defaults.
  ///
  /// Throws a [ManifestAuditConfigException] when the content is not YAML, or a
  /// key carries something other than the type it is documented with.
  factory ManifestAuditConfig.fromPubspec(String pubspec) {
    final section = _section(pubspec);
    if (section == null) return const ManifestAuditConfig();

    return ManifestAuditConfig(
      baseline: _stringOf(section, 'baseline', defaultBaseline),
      build: _nullableStringOf(section, 'build'),
      variants: _stringList(section, 'variants'),
      ignore: _stringList(section, 'ignore'),
    );
  }

  /// Baseline file, relative to the project root.
  ///
  /// It sits under `android/` because it describes the Android build output and
  /// nothing else in the project has an opinion about it.
  final String baseline;

  /// Root of the Android module's build outputs, relative to the project root.
  ///
  /// Unset means "find them": Flutter's build-directory redirection is a moving
  /// target and a monorepo may put the outputs anywhere, so the tool globs a
  /// bounded set of roots instead of composing a path from a template.
  final String? build;

  /// Variants audited when no `--variant` is given.
  ///
  /// Empty means every variant with a report on disk. A team that ships
  /// `prod-release` only does not want its debug builds failing a release
  /// check.
  final List<String> variants;

  /// Permission and component names left out of the report and the baseline.
  ///
  /// An entry covers the exact name. Unlike the path-prefix `ignore` of
  /// `appcraft_unused_assets` this is not a prefix match: a permission name is
  /// not a path, and `android.permission.READ_` covering everything under it
  /// would be a footgun.
  final List<String> ignore;

  /// Default value of [baseline].
  static const String defaultBaseline = 'android/manifest_audit.yaml';

  /// Throws a [ManifestAuditConfigException] when a path cannot be used.
  ///
  /// Both paths must stay inside the project: an absolute path or one climbing
  /// out of the root would let `baseline` write outside it.
  void validate() {
    _within('baseline', baseline);

    final build = this.build;
    if (build != null) _within('build', build);
  }

  static void _within(String key, String value) {
    if (value.trim().isEmpty) {
      throw ManifestAuditConfigException(
        'appcraft_manifest_audit: $key must not be empty.',
      );
    }

    if (p.isAbsolute(value)) {
      throw ManifestAuditConfigException(
        'appcraft_manifest_audit: $key must be relative to the project root, '
        'got "$value".',
      );
    }

    final normalized = p.posix.normalize(value.replaceAll(r'\', '/'));
    if (normalized == '..' || normalized.startsWith('../')) {
      throw ManifestAuditConfigException(
        'appcraft_manifest_audit: $key must stay inside the project root, '
        'got "$value".',
      );
    }
  }

  static String _stringOf(YamlMap section, String key, String fallback) =>
      _nullableStringOf(section, key) ?? fallback;

  static String? _nullableStringOf(YamlMap section, String key) {
    final value = section[key];
    if (value == null) return null;

    if (value is! String) {
      throw ManifestAuditConfigException(
        'appcraft_manifest_audit: $key must be a string, got "$value".',
      );
    }

    return value;
  }

  static List<String> _stringList(YamlMap section, String key) {
    final value = section[key];
    if (value == null) return const <String>[];

    if (value is! YamlList) {
      throw ManifestAuditConfigException(
        'appcraft_manifest_audit: $key must be a list, got "$value".',
      );
    }

    return <String>[
      for (final entry in value)
        if (entry is String)
          entry
        else
          throw ManifestAuditConfigException(
            'appcraft_manifest_audit: every entry of $key must be a string, '
            'got "$entry".',
          ),
    ];
  }

  static YamlMap? _section(String pubspec) {
    final Object? document;
    try {
      document = loadYaml(pubspec);
    } on YamlException catch (e) {
      throw ManifestAuditConfigException('pubspec.yaml is not valid YAML.\n$e');
    }
    if (document is! YamlMap) return null;

    final section = document['appcraft_manifest_audit'];
    return section is YamlMap ? section : null;
  }
}

/// Names of the `dependencies` and `dev_dependencies` of a `pubspec.yaml`.
///
/// These are the packages the developer wrote down. Everything else that turns
/// up as an owner arrived through one of them, which is what `report` says with
/// its `via`.
Set<String> declaredDependencies(String pubspec) {
  final document = loadYaml(pubspec);
  if (document is! YamlMap) return const <String>{};

  return <String>{
    for (final key in const <String>['dependencies', 'dev_dependencies'])
      if (document[key] case final YamlMap section)
        for (final name in section.keys)
          if (name is String) name,
  };
}
