/// Reader of the manifest merger's decision tree log.
///
/// The file is written by the Gradle manifest task to
/// `build/<module>/outputs/logs/manifest-merger-<variant>-report.txt`. Its
/// location is documented; the syntax of the lines inside it is not, and is an
/// implementation detail of the merger that happens to be stable. Everything
/// here is therefore pinned by recorded fixtures rather than by a
/// specification, and anything that does not match lands in
/// [MergerReport.unparsed] instead of being waved through.
library;

/// What the merger did with a node or an attribute.
///
/// The set is closed: it is the `Actions.ActionType` enum of the merger. An
/// unknown verb means the format changed.
enum MergeVerb {
  /// The node was taken from the manifest the line names.
  added('ADDED'),

  /// The merger itself wrote the value, nominally against the named manifest.
  injected('INJECTED'),

  /// The node existed already and the named manifest was merged into it.
  merged('MERGED'),

  /// The named manifest wanted the node and lost to a higher-priority one.
  rejected('REJECTED'),

  /// The merger granted a permission implied by a low `targetSdkVersion`.
  implied('IMPLIED'),

  /// The merger expanded the node into others, as it does a `<nav-graph>` into
  /// intent filters.
  converted('CONVERTED');

  const MergeVerb(this.keyword);

  /// Upper-case word the report writes.
  final String keyword;

  /// The verb spelled [keyword], or null when the report uses another word.
  static MergeVerb? of(String keyword) {
    for (final verb in values) {
      if (verb.keyword == keyword) return verb;
    }

    return null;
  }
}

/// Whoever a provenance line names as the origin of a node.
sealed class Owner {
  const Owner();

  /// Reads the text between the brackets of a provenance line.
  ///
  /// `null` is the app module's own manifest, whose source set is read off
  /// [path] instead. `[:sdk:]` is an artifact with no group and no version,
  /// not a subproject.
  factory Owner.parse(String? bracket, String path) {
    if (bracket == null) return SourceSetOwner(sourceSetOf(path));
    if (bracket.startsWith(':') && !bracket.endsWith(':')) {
      return SubprojectOwner(bracket.substring(1));
    }

    return MavenOwner.parse(bracket);
  }

  /// Source set a manifest path of the app module belongs to.
  ///
  /// `…/android/app/src/main/AndroidManifest.xml` is `app/src/main`. A path
  /// with no `src` segment — a generated manifest, for instance — falls back
  /// to the module directory alone.
  static String sourceSetOf(String path) {
    final segments = pathSegments(path);
    final index = segments.lastIndexOf('src');
    if (index == -1 || index + 1 >= segments.length) return 'app';

    final module = index > 0 ? segments[index - 1] : 'app';

    return '$module/src/${segments[index + 1]}';
  }
}

/// Segments of [path], split on either separator: the report writes the
/// separators of the machine that built it.
List<String> pathSegments(String path) => path.replaceAll(r'\', '/').split('/');

/// A manifest of the app module itself, told apart by its source set.
final class SourceSetOwner extends Owner {
  /// Creates an owner for [sourceSet], such as `app/src/main`.
  const SourceSetOwner(this.sourceSet);

  /// Source set the manifest belongs to, as `<module>/src/<name>`.
  final String sourceSet;

  @override
  bool operator ==(Object other) =>
      other is SourceSetOwner && other.sourceSet == sourceSet;

  @override
  int get hashCode => Object.hash(SourceSetOwner, sourceSet);

  @override
  String toString() => sourceSet;
}

/// A Gradle subproject, written `[:name]`.
///
/// In a Flutter project the subproject name is the pub package name of a
/// plugin, verbatim — the plugin loader includes `:${plugin.name}`. An app with
/// Android library modules of its own shows them the same way.
final class SubprojectOwner extends Owner {
  /// Creates an owner for the subproject called [name], without the colon.
  const SubprojectOwner(this.name);

  /// Gradle subproject name.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is SubprojectOwner && other.name == name;

  @override
  int get hashCode => Object.hash(SubprojectOwner, name);

  @override
  String toString() => ':$name';
}

/// A Maven artifact, written `[group:artifact:version]`.
final class MavenOwner extends Owner {
  /// Creates an owner for a resolved artifact.
  const MavenOwner({
    required this.group,
    required this.artifact,
    this.version,
  });

  /// Splits a coordinate, tolerating a missing version and a trailing
  /// classifier.
  factory MavenOwner.parse(String coordinate) {
    final parts = coordinate.split(':');

    return switch (parts.length) {
      0 || 1 => MavenOwner(group: '', artifact: coordinate),
      2 => MavenOwner(group: parts[0], artifact: parts[1]),
      3 when parts[2].isEmpty =>
        MavenOwner(group: parts[0], artifact: parts[1]),
      _ => MavenOwner(
          group: parts[0],
          artifact: parts[1],
          version: parts.sublist(2).join(':'),
        ),
    };
  }

  /// Maven group id.
  final String group;

  /// Maven artifact id.
  final String artifact;

  /// Resolved version, absent when the report omits it.
  final String? version;

  /// `group:artifact`, the part that survives a version bump.
  ///
  /// An artifact with no group is its name alone: `:sdk` would read as a
  /// Gradle subproject.
  String get module => group.isEmpty ? artifact : '$group:$artifact';

  @override
  bool operator ==(Object other) =>
      other is MavenOwner &&
      other.group == group &&
      other.artifact == artifact &&
      other.version == version;

  @override
  int get hashCode => Object.hash(MavenOwner, group, artifact, version);

  @override
  String toString() => version == null ? module : '$module:$version';
}

/// Where in a manifest a node or an attribute sits.
final class Position {
  /// Creates a position.
  const Position({
    required this.line,
    required this.column,
    this.endLine,
    this.endColumn,
  });

  /// One-based line the node starts on.
  final int line;

  /// One-based column the node starts at.
  final int column;

  /// Line the node ends on, absent when it ends on [line].
  final int? endLine;

  /// Column the node ends at, absent when the report gives none.
  final int? endColumn;

  @override
  bool operator ==(Object other) =>
      other is Position &&
      other.line == line &&
      other.column == column &&
      other.endLine == endLine &&
      other.endColumn == endColumn;

  @override
  int get hashCode => Object.hash(line, column, endLine, endColumn);

  @override
  String toString() {
    final buffer = StringBuffer('$line:$column');
    if (endLine != null) buffer.write('-$endLine');
    if (endColumn != null) buffer.write(endLine == null ? '-' : ':');
    if (endColumn != null) buffer.write('$endColumn');

    return buffer.toString();
  }
}

/// One `<VERB> from …` line of the report.
final class Provenance {
  /// Creates a provenance entry.
  const Provenance({
    required this.verb,
    required this.owner,
    required this.path,
    this.position,
    this.reason,
  });

  /// What the merger did.
  final MergeVerb verb;

  /// Who the line names as the origin.
  final Owner owner;

  /// Manifest file the line names, exactly as written.
  ///
  /// For an [MergeVerb.injected] line this file often does not contain the
  /// value at all — AGP writes `minSdkVersion`, `versionCode` and their like
  /// from the Gradle DSL and still cites a manifest.
  final String path;

  /// Position inside [path], absent on the lines that carry none.
  final Position? position;

  /// Text of a trailing ` reason: …`, absent when there is none.
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is Provenance &&
      other.verb == verb &&
      other.owner == owner &&
      other.path == path &&
      other.position == position &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(verb, owner, path, position, reason);
}

/// An attribute of a node, with the manifests that wrote it.
final class ReportAttribute {
  /// Creates an attribute.
  const ReportAttribute({
    required this.name,
    required this.provenance,
  });

  /// Attribute name as the report writes it, `android:maxSdkVersion`.
  final String name;

  /// Lines under the attribute, deduplicated.
  final List<Provenance> provenance;
}

/// A node of the merged manifest, with everything the report says about it.
final class ReportNode {
  /// Creates a node.
  ReportNode({
    required this.element,
    required this.key,
    required this.provenance,
    required this.attributes,
  });

  /// Element name, with the `android:` prefix of old AGP stripped.
  final String element;

  /// Part of the node key after the first `#`, absent for a keyless node.
  ///
  /// It carries `:`, `+`, `*` and `/` of its own —
  /// `intent#action:name:android.intent.action.GET_CONTENT+data:mimeType:*/*`
  /// is one key — so the split is on the first `#` only.
  final String? key;

  /// Lines directly under the node key, deduplicated.
  final List<Provenance> provenance;

  /// Attributes of the node, in the order the report lists them.
  final List<ReportAttribute> attributes;

  /// The node key as the report writes it.
  String get nodeKey => key == null ? element : '$element#$key';

  /// Owners that got the node into the manifest, without repetition.
  ///
  /// [MergeVerb.rejected] is left out: a rejected library wanted the node and
  /// lost, so naming it as an owner would be wrong. It stays available through
  /// [rejectedProvenance].
  List<Provenance> get acceptedProvenance => <Provenance>[
        for (final entry in provenance)
          if (entry.verb != MergeVerb.rejected) entry,
      ];

  /// Owners that wanted the node and lost to a higher-priority manifest.
  List<Provenance> get rejectedProvenance => <Provenance>[
        for (final entry in provenance)
          if (entry.verb == MergeVerb.rejected) entry,
      ];
}

/// Everything a decision tree log holds.
final class MergerReport {
  /// Creates a report.
  const MergerReport({
    required this.nodes,
    required this.unparsed,
  });

  /// Nodes in the order the report lists them.
  final List<ReportNode> nodes;

  /// Lines that matched nothing in the grammar.
  ///
  /// A gap is never presented as an absence: the count is printed by `report`
  /// and `check`, so a format change shows up as a number rather than as a
  /// shorter list.
  final List<String> unparsed;

  /// The node keyed [nodeKey], or null.
  ReportNode? nodeOf(String nodeKey) {
    for (final node in nodes) {
      if (node.nodeKey == nodeKey) return node;
    }

    return null;
  }

  /// Every node whose element is [element].
  List<ReportNode> nodesOf(String element) => <ReportNode>[
        for (final node in nodes)
          if (node.element == element) node,
      ];
}

/// Header the merger writes as the first line.
const String _header = '-- Merging decision tree log ---';

final RegExp _provenance = RegExp(r'^([A-Z]+) from (?:\[([^\]]*)\] )?(.+)$');
final RegExp _position = RegExp(r':(\d+):(\d+)(?:-(\d+)(?::(\d+))?)?$');
final RegExp _nodeKey =
    RegExp(r'^[A-Za-z][\w.-]*(?::[A-Za-z][\w.-]*)?(?:#.*)?$');

/// Reads a decision tree log.
///
/// Never throws: a line that does not fit the grammar lands in
/// [MergerReport.unparsed], including a line carrying a verb the merger does
/// not have.
MergerReport parseMergerReport(String content) {
  final nodes = <ReportNode>[];
  final unparsed = <String>[];

  ReportNode? node;
  ReportAttribute? attribute;

  for (final raw in content.split('\n')) {
    final line = raw.replaceAll('\r', '');
    if (line.trim().isEmpty) continue;

    var depth = 0;
    while (depth < line.length && line[depth] == '\t') {
      depth++;
    }
    final text = line.substring(depth).trimRight();

    if (depth == 0) {
      if (text == _header) continue;

      final entry = _parseProvenance(text);
      if (entry != null) {
        if (node == null) {
          unparsed.add(line);
          continue;
        }
        _add(node.provenance, entry);
        continue;
      }

      if (!_nodeKey.hasMatch(text)) {
        unparsed.add(line);
        continue;
      }

      node = _parseNodeKey(text);
      attribute = null;
      nodes.add(node);
      continue;
    }

    if (node == null) {
      unparsed.add(line);
      continue;
    }

    if (depth == 1) {
      // An attribute name, never a provenance line: the verbs live one level
      // deeper and every one of them carries a space.
      if (text.contains(' ')) {
        unparsed.add(line);
        continue;
      }

      attribute = ReportAttribute(name: text, provenance: <Provenance>[]);
      node.attributes.add(attribute);
      continue;
    }

    final entry = _parseProvenance(text);
    if (entry == null || attribute == null) {
      unparsed.add(line);
      continue;
    }

    _add(attribute.provenance, entry);
  }

  return MergerReport(nodes: nodes, unparsed: unparsed);
}

/// Appends [entry] unless the same line was already recorded.
///
/// Nearly every `MERGED from` line of an app-level report appears twice,
/// verbatim and adjacent. Without this every count doubles.
void _add(List<Provenance> provenance, Provenance entry) {
  if (provenance.contains(entry)) return;

  provenance.add(entry);
}

ReportNode _parseNodeKey(String text) {
  final hash = text.indexOf('#');
  var element = hash == -1 ? text : text.substring(0, hash);
  final key = hash == -1 ? null : text.substring(hash + 1);

  // Old AGP prefixed the element with its namespace:
  // `android:uses-permission#android.permission.WRITE_EXTERNAL_STORAGE`.
  if (element.startsWith('android:')) element = element.substring(8);

  return ReportNode(
    element: element,
    key: key,
    provenance: <Provenance>[],
    attributes: <ReportAttribute>[],
  );
}

Provenance? _parseProvenance(String text) {
  final match = _provenance.firstMatch(text);
  if (match == null) return null;

  final verb = MergeVerb.of(match.group(1)!);
  if (verb == null) return null;

  var tail = match.group(3)!;

  // The reason comes off first: without it the position matcher would run
  // against the reason text instead of the path.
  String? reason;
  final marker = tail.indexOf(' reason: ');
  if (marker != -1) {
    reason = tail.substring(marker + 9).trim();
    tail = tail.substring(0, marker);
  }

  Position? position;
  final located = _position.firstMatch(tail);
  if (located != null) {
    position = _positionOf(located);
    tail = tail.substring(0, located.start);
  }

  return Provenance(
    verb: verb,
    owner: Owner.parse(match.group(2), tail),
    path: tail,
    position: position,
    reason: reason,
  );
}

Position _positionOf(RegExpMatch match) {
  final line = int.parse(match.group(1)!);
  final column = int.parse(match.group(2)!);
  final third = match.group(3);
  final fourth = match.group(4);

  if (third == null) return Position(line: line, column: column);

  // `14:5-87:19` ends on another line, `11:5-47` ends on the same one.
  if (fourth == null) {
    return Position(line: line, column: column, endColumn: int.parse(third));
  }

  return Position(
    line: line,
    column: column,
    endLine: int.parse(third),
    endColumn: int.parse(fourth),
  );
}
