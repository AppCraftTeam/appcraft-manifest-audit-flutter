import 'merged_manifest.dart';
import 'merger_report.dart';
import 'plugins.dart';

/// An owner of the report, resolved as far as the tool honestly can.
sealed class ResolvedOwner {
  const ResolvedOwner();

  /// What `report` prints.
  String get label;

  /// What the baseline records.
  ///
  /// Deliberately narrower than [label]: a `via` churns without the answer
  /// changing, and a baseline is read in a pull request.
  String get baselineKey;

  /// Trailing comment the baseline carries next to [baselineKey], if any.
  String? get note => null;
}

/// The app module's own manifest.
final class AppOwner extends ResolvedOwner {
  /// Creates an owner for [sourceSet], such as `app/src/main`.
  const AppOwner(this.sourceSet);

  /// Source set the declaration sits in.
  ///
  /// `app/src/debug` is worth reading twice: Flutter's own debug manifest
  /// declares `INTERNET` for hot reload, and that permission never ships.
  final String sourceSet;

  @override
  String get label => sourceSet;

  @override
  String get baselineKey => sourceSet;
}

/// A pub package, reached as a Gradle subproject.
final class PluginOwner extends ResolvedOwner {
  /// Creates a plugin owner.
  const PluginOwner({
    required this.package,
    this.version,
    this.via = const <String>[],
    this.devDependency = false,
    this.source,
  });

  /// Pub package name.
  final String package;

  /// Version of the package, absent for a path or git dependency.
  final String? version;

  /// Packages a pubspec names instead of this one.
  final List<String> via;

  /// Whether the package is a dev dependency, and therefore absent from a
  /// release build.
  final bool devDependency;

  /// Where the package declares the node in its own sources, when its report
  /// was on disk.
  final SourceReference? source;

  @override
  String get label =>
      via.isEmpty ? package : '$package (via ${via.join(', ')})';

  @override
  String get baselineKey => package;
}

/// A Gradle subproject with no entry in `.flutter-plugins-dependencies`.
///
/// An app with Android library modules of its own, or a monorepo with shared
/// native modules, shows them exactly like plugins. Saying so is right and
/// tells you nothing about which part of your own codebase to look in.
final class ModuleOwner extends ResolvedOwner {
  /// Creates an owner for the subproject called [name].
  const ModuleOwner(this.name);

  /// Gradle subproject name, without the colon.
  final String name;

  @override
  String get label => '$name (local Gradle module)';

  @override
  String get baselineKey => ':$name';

  @override
  String get note => 'local Gradle module';
}

/// A Maven artifact, named as the report names it.
///
/// The report says nothing about which package pulled the artifact in, and a
/// plugin's own report does not either: AGP merges a library's manifest
/// without its dependencies. `gradlew :app:dependencies` shows the path, so
/// the tool names the artifact rather than the nearest plausible plugin.
final class ArtifactOwner extends ResolvedOwner {
  /// Creates an owner for [artifact].
  const ArtifactOwner(this.artifact);

  /// The artifact the report named.
  final MavenOwner artifact;

  @override
  String get label => artifact.module;

  @override
  String get baselineKey => artifact.module;
}

/// A value AGP writes from the Gradle DSL rather than from any manifest.
///
/// `minSdkVersion`, `versionCode`, `android:name` and `android:extractNativeLibs`
/// arrive this way. The report still cites a manifest file, which does not
/// contain them, so following the path it gives leads nowhere.
final class GradleOwner extends ResolvedOwner {
  /// Creates the owner.
  const GradleOwner();

  @override
  String get label => 'Gradle (android/app/build.gradle)';

  @override
  String get baselineKey => 'Gradle';
}

/// A place in a package's own sources.
final class SourceReference {
  /// Creates a reference.
  const SourceReference({required this.path, this.line});

  /// Path relative to the package root, `android/src/main/AndroidManifest.xml`.
  final String path;

  /// One-based line, absent when the report gives no position.
  final int? line;

  @override
  String toString() => line == null ? path : '$path:$line';
}

/// One owner of one entry, with the report line it came from.
final class OwnerRecord {
  /// Creates a record.
  const OwnerRecord({required this.owner, required this.provenance});

  /// Who it was.
  final ResolvedOwner owner;

  /// The line of the app-level report that named it.
  final Provenance provenance;
}

/// An attribute of an entry, with the manifests that wrote it.
///
/// The owner of an attribute is not the owner of the node: a permission
/// declared by the app can carry an `android:maxSdkVersion` written by a
/// plugin. Play reads the node, so only node owners reach the baseline; this is
/// what `explain` answers "why does my permission have a maxSdkVersion I did
/// not write" with.
final class AttributedAttribute {
  /// Creates an attribute.
  const AttributedAttribute({required this.name, required this.owners});

  /// Attribute name as the report writes it.
  final String name;

  /// Who wrote it.
  final List<OwnerRecord> owners;
}

/// A permission or a component, with everyone responsible for it.
final class AttributedEntry {
  /// Creates an entry.
  const AttributedEntry({
    required this.key,
    required this.owners,
    this.rejected = const <OwnerRecord>[],
    this.attributes = const <AttributedAttribute>[],
  });

  /// Permission as [ManifestNodes.permissionKey] spells it, or a component as
  /// `<element>#<android:name>`.
  final String key;

  /// Whoever got it into the manifest.
  final List<OwnerRecord> owners;

  /// Whoever wanted it and lost to a higher-priority manifest.
  ///
  /// `REJECTED from` means the opposite of what it looks like: the library
  /// declared the node and another one won. It belongs in `explain` and not in
  /// the owner list, so the two outputs deliberately disagree here.
  final List<OwnerRecord> rejected;

  /// Attributes of the node.
  final List<AttributedAttribute> attributes;

  /// Whether any owner is a manifest of the app module itself.
  bool get declaredByApp => owners.any((record) => record.owner is AppOwner);

  /// Owner labels, without repetition, sorted.
  List<String> get labels => _sortedUnique(owners.map((r) => r.owner.label));

  /// Owners as the baseline records them, without repetition, sorted.
  List<BaselineOwner> get baselineOwners {
    final byKey = <String, BaselineOwner>{};
    for (final record in owners) {
      byKey.putIfAbsent(
        record.owner.baselineKey,
        () => BaselineOwner(
          key: record.owner.baselineKey,
          note: record.owner.note,
        ),
      );
    }

    final sorted = byKey.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return sorted;
  }
}

/// An owner as it appears in the baseline file.
final class BaselineOwner {
  /// Creates a baseline owner.
  const BaselineOwner({required this.key, this.note});

  /// What the file records.
  final String key;

  /// Trailing comment, if any.
  final String? note;

  @override
  bool operator ==(Object other) => other is BaselineOwner && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The `<queries>` block, summarised.
///
/// A release report can hold roughly two hundred `<package>` entries, mostly
/// banking-app identifiers from a payment SDK. Listing them would bury the
/// twenty entries that matter, so `report` gives a count and the libraries
/// behind it. A single new `<package>` is therefore invisible in `report`.
final class QueriesSummary {
  /// Creates a summary.
  const QueriesSummary({required this.packages, required this.owners});

  /// Number of `<package>` entries.
  final int packages;

  /// Libraries that contributed them, sorted.
  final List<String> owners;

  /// Whether the report held a `<queries>` block at all.
  bool get isEmpty => packages == 0;
}

/// Everything one variant's audit produced.
final class Attribution {
  /// Creates an attribution.
  const Attribution({
    required this.variant,
    required this.permissions,
    required this.components,
    required this.suppressed,
    required this.unattributed,
    required this.queries,
    required this.unparsed,
    this.applicationId,
    this.degraded = false,
  });

  /// Variant this describes, hyphen-joined and lower-case.
  final String variant;

  /// Permissions the merged manifest holds, sorted by key.
  final List<AttributedEntry> permissions;

  /// Components the merged manifest holds, sorted by key.
  final List<AttributedEntry> components;

  /// Entries the report records and the merged manifest does not hold.
  ///
  /// That is what a `tools:node="remove"` looks like from here: the merger logs
  /// the decision it considered and then drops the node.
  final List<AttributedEntry> suppressed;

  /// Names in the merged manifest with no node in the report, sorted.
  ///
  /// A gap, never presented as an absence.
  final List<String> unattributed;

  /// The `<queries>` block, summarised.
  final QueriesSummary queries;

  /// Lines of the report that matched nothing in the grammar.
  final int unparsed;

  /// Application id of the variant, absent when the manifest carries none.
  final String? applicationId;

  /// Whether the run had no merged manifest and no blame file.
  ///
  /// Attribution still works from the report alone, but the correction of a
  /// removed node cannot be applied, so every entry is "considered" rather than
  /// "present".
  final bool degraded;
}

/// Attributes a variant's merged manifest to the libraries that filled it.
///
/// [nodes] being null is a degraded run: neither the merged manifest nor the
/// blame file was on disk, so the report is taken at its word.
///
/// [pluginReports] are the per-plugin decision tree logs, keyed by pub package
/// name. They give the place in a plugin's own sources a `[:name]` node comes
/// from.
Attribution attribute({
  required String variant,
  required MergerReport report,
  required ManifestNodes? nodes,
  PluginIndex? plugins,
  Map<String, MergerReport> pluginReports = const <String, MergerReport>{},
  List<String> ignore = const <String>[],
}) {
  final index = plugins ?? PluginIndex.empty;
  final keys = _keysOf(report);
  final applicationId = nodes?.applicationId ?? _inferApplicationId(keys);
  final placeholders = _placeholdersOf(keys, applicationId);

  final resolver = _Resolver(plugins: index, pluginReports: pluginReports);

  final permissions = _entries(
    report: report,
    resolver: resolver,
    placeholders: placeholders,
    elements: ManifestNodes.permissionElements,
    keyed: true,
  );
  final components = _entries(
    report: report,
    resolver: resolver,
    placeholders: placeholders,
    elements: ManifestNodes.componentElements,
    keyed: false,
  );

  final present = <String>{
    ...?nodes?.permissions.map((key) => _folded(key, placeholders)),
    ...?nodes?.components.map((key) => _folded(key, placeholders)),
  };

  final kept = <AttributedEntry>[];
  final suppressed = <AttributedEntry>[];
  final keptComponents = <AttributedEntry>[];

  for (final entry in <(AttributedEntry, bool)>[
    for (final entry in permissions) (entry, true),
    for (final entry in components) (entry, false),
  ]) {
    final (attributed, isPermission) = entry;
    if (ignore.contains(attributed.key)) continue;

    if (nodes == null || present.contains(attributed.key)) {
      (isPermission ? kept : keptComponents).add(attributed);
      continue;
    }

    suppressed.add(attributed);
  }

  final attributed = <String>{
    for (final entry in permissions) entry.key,
    for (final entry in components) entry.key,
  };
  final unattributed = <String>[
    for (final name in present)
      if (!attributed.contains(name) && !ignore.contains(name)) name,
  ]..sort();

  return Attribution(
    variant: variant,
    permissions: kept,
    components: keptComponents,
    suppressed: suppressed,
    unattributed: unattributed,
    queries: _queriesOf(report, resolver),
    unparsed: report.unparsed.length,
    applicationId: applicationId,
    degraded: nodes == null,
  );
}

/// Builds the entries of the elements in [elements].
///
/// Nodes sharing a key after placeholder folding become one entry: the report
/// holds `${applicationId}.X` and its substituted twin as separate nodes, both
/// from the same library, and counting them apart doubles them.
List<AttributedEntry> _entries({
  required MergerReport report,
  required _Resolver resolver,
  required Map<String, String> placeholders,
  required Set<String> elements,
  required bool keyed,
}) {
  final owners = <String, List<OwnerRecord>>{};
  final rejected = <String, List<OwnerRecord>>{};
  final attributes = <String, List<AttributedAttribute>>{};

  for (final node in report.nodes) {
    if (!elements.contains(node.element)) continue;

    final name = node.key;
    if (name == null) continue;

    final folded = placeholders[name] ?? name;
    final key = keyed
        ? ManifestNodes.permissionKey(node.element, folded)
        : '${node.element}#$folded';

    owners
        .putIfAbsent(key, () => <OwnerRecord>[])
        .addAll(resolver.records(node.acceptedProvenance, node));
    rejected
        .putIfAbsent(key, () => <OwnerRecord>[])
        .addAll(resolver.records(node.rejectedProvenance, node));

    for (final attribute in node.attributes) {
      attributes.putIfAbsent(key, () => <AttributedAttribute>[]).add(
            AttributedAttribute(
              name: attribute.name,
              owners: resolver.records(attribute.provenance, node,
                  isAttribute: true),
            ),
          );
    }
  }

  final keys = owners.keys.toList()..sort();

  return <AttributedEntry>[
    for (final key in keys)
      AttributedEntry(
        key: key,
        owners: owners[key]!,
        rejected: rejected[key] ?? const <OwnerRecord>[],
        attributes: attributes[key] ?? const <AttributedAttribute>[],
      ),
  ];
}

QueriesSummary _queriesOf(MergerReport report, _Resolver resolver) {
  final packages = report.nodesOf('package');
  final owners = <String>{};

  for (final node in packages) {
    for (final record in resolver.records(node.acceptedProvenance, node)) {
      owners.add(record.owner.label);
    }
  }

  return QueriesSummary(
    packages: packages.length,
    owners: owners.toList()..sort(),
  );
}

/// Maps a substituted permission name to its `${applicationId}` twin.
///
/// Only names the report holds in both forms are folded, which is the case the
/// merger creates: `androidx.core` declares the placeholder, the merger
/// substitutes it, and both end up in the log as separate nodes. A baseline
/// keyed on the substituted form would differ between flavours for no reason.
Map<String, String> _placeholdersOf(Set<String> keys, String? applicationId) {
  if (applicationId == null) return const <String, String>{};

  final folded = <String, String>{};
  for (final key in keys) {
    if (!key.startsWith(_applicationIdPlaceholder)) continue;

    final substituted =
        applicationId + key.substring(_applicationIdPlaceholder.length);
    if (keys.contains(substituted)) folded[substituted] = key;
  }

  return folded;
}

/// Reads the application id off a `${applicationId}` pair of the report.
///
/// Used when the merged manifest is not on disk, or carries no `package`
/// attribute: the report holds both the placeholder node and its substituted
/// twin, and the difference between the two keys is the application id.
String? _inferApplicationId(Set<String> keys) {
  for (final key in keys) {
    if (!key.startsWith(_applicationIdPlaceholder)) continue;

    final suffix = key.substring(_applicationIdPlaceholder.length);
    for (final candidate in keys) {
      if (candidate != key && candidate.endsWith(suffix)) {
        return candidate.substring(0, candidate.length - suffix.length);
      }
    }
  }

  return null;
}

const String _applicationIdPlaceholder = r'${applicationId}';

/// Keys of the report's nodes, the part after the first `#`.
Set<String> _keysOf(MergerReport report) => <String>{
      for (final node in report.nodes)
        if (node.key case final String key) key,
    };

/// [key] of a manifest node, its name folded onto the `${applicationId}` twin.
String _folded(String key, Map<String, String> placeholders) {
  final hash = key.indexOf('#');
  final name = key.substring(hash + 1);
  final folded = placeholders[name] ?? name;

  return hash == -1 ? folded : '${key.substring(0, hash)}#$folded';
}

List<String> _sortedUnique(Iterable<String> values) {
  final unique = values.toSet().toList()..sort();

  return unique;
}

/// Turns the owners the report names into owners a reader can act on.
final class _Resolver {
  _Resolver({
    required this.plugins,
    required this.pluginReports,
  });

  final PluginIndex plugins;
  final Map<String, MergerReport> pluginReports;

  List<OwnerRecord> records(
    List<Provenance> provenance,
    ReportNode node, {
    bool isAttribute = false,
  }) {
    final records = <OwnerRecord>[];

    for (final line in provenance) {
      records.add(OwnerRecord(
        owner: _resolve(line, node, isAttribute: isAttribute),
        provenance: line,
      ));
    }

    return records;
  }

  ResolvedOwner _resolve(
    Provenance line,
    ReportNode node, {
    required bool isAttribute,
  }) =>
      switch (line.owner) {
        SourceSetOwner(:final sourceSet) =>
          _isGradleInjection(line, node, isAttribute: isAttribute)
              ? const GradleOwner()
              : AppOwner(sourceSet),
        SubprojectOwner(:final name) => _subproject(name, node),
        MavenOwner artifact => ArtifactOwner(artifact),
      };

  /// Whether the line records a value AGP wrote from the Gradle DSL.
  ///
  /// Narrow on purpose. Every `INJECTED` line cites a manifest of the app
  /// module, and most of them cite it truthfully — Flutter's debug manifest
  /// really does declare `INTERNET`. The values that come from the DSL land on
  /// `uses-sdk` and on attributes of `manifest` and `application`, and nowhere
  /// near a permission or a component.
  bool _isGradleInjection(
    Provenance line,
    ReportNode node, {
    required bool isAttribute,
  }) =>
      line.verb == MergeVerb.injected &&
      (isAttribute || node.element == 'uses-sdk');

  ResolvedOwner _subproject(String name, ReportNode node) {
    final plugin = plugins[name];
    if (plugin == null) return ModuleOwner(name);

    return PluginOwner(
      package: plugin.name,
      version: plugin.version,
      via: plugin.via,
      devDependency: plugin.devDependency,
      source: _sourceOf(plugin.name, node),
    );
  }

  /// Where [package] declares [node] in its own sources.
  ///
  /// The app-level report points at the plugin's *merged* manifest under
  /// `build/`, which is no use to a reader. The plugin's own report resolves to
  /// the pub cache, and the tail of that path is the file to open.
  SourceReference? _sourceOf(String package, ReportNode node) {
    final report = pluginReports[package];
    if (report == null) return null;

    final key = node.key;
    final own = report.nodeOf(node.nodeKey) ??
        (key == null ? null : report.nodeOf('${node.element}#$key'));
    if (own == null) return null;

    for (final line in own.acceptedProvenance) {
      if (line.owner is! SourceSetOwner) continue;

      return SourceReference(
        path: relativeManifestPath(line.path),
        line: line.position?.line,
      );
    }

    return null;
  }
}

/// The tail of a manifest path that is worth printing.
///
/// `…\pub.dev\appsflyer_sdk-6.15.2\android\src\main\AndroidManifest.xml`
/// becomes `android/src/main/AndroidManifest.xml`; a path with no source set —
/// an exploded AAR — keeps its file name alone.
String relativeManifestPath(String path) {
  final segments = pathSegments(path);
  if (segments.isEmpty) return path;

  final index = segments.lastIndexOf('src');
  if (index <= 0) return segments.last;

  return segments.sublist(index - 1).join('/');
}
