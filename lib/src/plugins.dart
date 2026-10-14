import 'dart:convert';

import 'merger_report.dart';

/// A pub package that becomes a Gradle subproject of the Android build.
final class PubPlugin {
  /// Creates a plugin entry.
  const PubPlugin({
    required this.name,
    required this.path,
    this.version,
    this.devDependency = false,
    this.via = const <String>[],
  });

  /// Pub package name, which is also the Gradle subproject name.
  ///
  /// Flutter's plugin loader includes `:${plugin.name}` and points it at
  /// `${plugin.path}/android`, so the two are the same string with no
  /// transformation. This is an identity, not a heuristic.
  final String name;

  /// Directory of the package, as the file gives it.
  ///
  /// Never reconstructed: on Windows the pub cache is under
  /// `AppData\Local\Pub\Cache` rather than `~/.pub-cache`, the separators are
  /// escaped and there is a trailing one.
  final String path;

  /// Version read off the pub cache directory name, absent for a path or git
  /// dependency.
  final String? version;

  /// Whether the package is a dev dependency.
  ///
  /// Modern Flutter leaves those out of a release build, so their permissions
  /// are in the debug manifest and not in the release one.
  final bool devDependency;

  /// Packages a pubspec is likely to name instead of this one.
  ///
  /// A federated implementation such as `camera_android_camerax` is pulled in
  /// by `camera`, and reporting the implementation alone names a package nobody
  /// wrote down.
  final List<String> via;
}

/// `.flutter-plugins-dependencies`, read into the shape attribution needs.
final class PluginIndex {
  /// Creates an index over [plugins], keyed by package name.
  PluginIndex(Iterable<PubPlugin> plugins)
      : byName = <String, PubPlugin>{
          for (final plugin in plugins) plugin.name: plugin,
        };

  /// Reads the file.
  ///
  /// Entries with `"native_build": false` are dropped: a Dart-only federated
  /// implementation never becomes a Gradle project, so it can never be an
  /// owner.
  ///
  /// [declared] are the packages the project's `pubspec.yaml` names. One of
  /// them is what the developer wrote down, so it gets no `via` however deep
  /// the dependency graph puts it.
  ///
  /// Throws a [FormatException] when the content is not JSON.
  factory PluginIndex.parse(
    String content, {
    Set<String> declared = const <String>{},
  }) {
    final document = jsonDecode(content);
    if (document is! Map<String, Object?>) return PluginIndex(const []);

    final plugins = document['plugins'];
    final android = plugins is Map<String, Object?> ? plugins['android'] : null;
    if (android is! List) return PluginIndex(const []);

    final parents = _parentsOf(document['dependencyGraph']);

    return PluginIndex(<PubPlugin>[
      for (final entry in android)
        if (entry is Map<String, Object?>)
          if (entry['name'] case final String name)
            if (entry['native_build'] != false)
              PubPlugin(
                name: name,
                path: entry['path'] as String? ?? '',
                version: _versionOf(name, entry['path'] as String? ?? ''),
                devDependency: entry['dev_dependency'] == true,
                via: declared.contains(name)
                    ? const <String>[]
                    : _rootsOf(name, parents),
              ),
    ]);
  }

  /// An empty index, for a project whose file is not on disk.
  static final PluginIndex empty = PluginIndex(const <PubPlugin>[]);

  /// Plugins by pub package name.
  final Map<String, PubPlugin> byName;

  /// The plugin called [name], or null when the file does not list it.
  ///
  /// A `[:name]` with no entry here is a local Gradle module of the app rather
  /// than a package.
  PubPlugin? operator [](String name) => byName[name];

  /// Version read off a pub cache directory such as
  /// `…/pub.dev/firebase_messaging-15.2.10/`.
  static String? _versionOf(String name, String path) {
    final segments =
        pathSegments(path).where((segment) => segment.isNotEmpty).toList();
    if (segments.isEmpty) return null;

    final directory = segments.last;
    if (!directory.startsWith('$name-')) return null;

    return directory.substring(name.length + 1);
  }

  /// Maps every package to the packages that depend on it.
  static Map<String, Set<String>> _parentsOf(Object? graph) {
    final parents = <String, Set<String>>{};
    if (graph is! List) return parents;

    for (final entry in graph) {
      if (entry is! Map<String, Object?>) continue;

      final name = entry['name'];
      final dependencies = entry['dependencies'];
      if (name is! String || dependencies is! List) continue;

      for (final dependency in dependencies) {
        if (dependency is String) {
          parents.putIfAbsent(dependency, () => <String>{}).add(name);
        }
      }
    }

    return parents;
  }

  /// Packages that depend on [name] and that nothing depends on in turn.
  ///
  /// Those are the ones a pubspec names. A package nothing depends on is a
  /// direct dependency itself and gets an empty list.
  static List<String> _rootsOf(String name, Map<String, Set<String>> parents) {
    final roots = <String>{};
    final seen = <String>{name};
    final queue = <String>[...?parents[name]];

    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!seen.add(current)) continue;

      final above = parents[current];
      if (above == null || above.isEmpty) {
        roots.add(current);
        continue;
      }

      queue.addAll(above);
    }

    final sorted = roots.toList()..sort();

    return sorted;
  }
}
