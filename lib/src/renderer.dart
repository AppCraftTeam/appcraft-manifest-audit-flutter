import 'attribution.dart';
import 'auditor.dart';
import 'baseline.dart';
import 'merged_manifest.dart';
import 'merger_report.dart';

/// Column the second field of a line starts at.
const int _column = 55;

/// Renders one variant's `report` output.
///
/// Grouping by *who* rather than by *what* is the whole readability win over
/// the raw decision tree log: everything in the second block is a candidate for
/// a Data Safety question.
String renderReport(VariantAudit audit) {
  final attribution = audit.attribution;
  final buffer = StringBuffer();

  _warnings(buffer, audit);

  buffer
    ..writeln('${attribution.variant} — '
        '${attribution.permissions.length} permission(s), '
        '${attribution.components.length} component(s)')
    ..writeln();

  final own = <AttributedEntry>[
    for (final entry in attribution.permissions)
      if (entry.declaredByApp) entry,
  ];
  final injected = <AttributedEntry>[
    for (final entry in attribution.permissions)
      if (!entry.declaredByApp) entry,
  ];

  _entries(buffer, 'Permissions the app declares itself', own);
  _entries(buffer, 'Permissions injected by libraries', injected);

  if (attribution.suppressed.isNotEmpty) {
    buffer.writeln(
      'Suppressed by tools:node="remove" (${attribution.suppressed.length}):',
    );
    for (final entry in attribution.suppressed) {
      buffer.writeln(_line(entry.key, _suppression(entry)));
    }
    buffer.writeln();
  }

  if (attribution.unattributed.isNotEmpty) {
    buffer.writeln(
      'In the manifest with no node in the report '
      '(${attribution.unattributed.length}):',
    );
    for (final name in attribution.unattributed) {
      buffer.writeln(_line(name, 'unattributed'));
    }
    buffer.writeln();
  }

  final libraries = <String>{
    for (final entry in attribution.components) ...entry.labels,
  };
  buffer.writeln(
    'Components: ${attribution.components.length}, from '
    '${_count(libraries.length, 'library', plural: 'libraries')}. '
    'Run "explain" for one of them.',
  );

  final queries = attribution.queries;
  if (!queries.isEmpty) {
    buffer.writeln(
      'queries: ${queries.packages} <package> entries from '
      '${_count(queries.owners.length, 'library', plural: 'libraries')} — not '
      'listed, see "explain queries".',
    );
  }

  _unparsed(buffer, attribution);

  return buffer.toString();
}

/// Renders one variant's `check` output.
///
/// Silence and 0 is the normal CI outcome, so an empty diff renders to nothing.
String renderCheck(BaselineDiff diff, {required bool strict}) {
  if (diff.isEmpty) return '';

  final buffer = StringBuffer()
    ..writeln('${diff.variant}: ${_summary(diff)}')
    ..writeln();

  _diffEntries(buffer, diff);

  buffer
    ..writeln()
    ..writeln(
      'Review them, then run "dart run appcraft_manifest_audit baseline" and '
      'commit the change. A permission that contradicts the Data Safety '
      'declaration is what gets a release rejected.',
    );

  if (!strict && !diff.fails(strict: false)) {
    final strictOnly = <String>{
      for (final kind in DiffKind.values)
        if (!kind.failsByDefault) _changes(kind),
    }.toList();
    final listed = strictOnly.length == 1
        ? strictOnly.single
        : '${strictOnly.take(strictOnly.length - 1).join(', ')} and '
            '${strictOnly.last}';

    buffer.writeln(
      'None of this fails the check by default. Run with --strict to make '
      '$listed fail as well.',
    );
  }

  return buffer.toString();
}

/// Renders the diff `baseline --dry-run` would write.
String renderBaselineDiff(BaselineDiff diff) {
  if (diff.isEmpty) return '${diff.variant}: the baseline is up to date.\n';

  final buffer = StringBuffer()..writeln('${diff.variant}: ${_summary(diff)}');
  _diffEntries(buffer, diff);

  return buffer.toString();
}

/// Renders `explain` for everything matching [query].
///
/// The removal snippet at the end is what the developer came for, and "as a
/// direct child of `<manifest>`" is there because getting it wrong is a real
/// and silent failure: a `tools:node="remove"` nested inside an `<activity>` is
/// ignored without an error, a warning or an effect.
String renderExplain(List<VariantAudit> audits, String query) {
  final buffer = StringBuffer();

  if (query == 'queries') {
    for (final audit in audits) {
      final queries = audit.attribution.queries;
      buffer
        ..writeln('queries — ${audit.attribution.variant}')
        ..writeln();
      if (queries.isEmpty) {
        buffer.writeln('  No <queries> block in the report.');
      } else {
        buffer.writeln('  ${queries.packages} <package> entries, from:');
        for (final owner in queries.owners) {
          buffer.writeln('    $owner');
        }
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  for (final audit in audits) {
    final attribution = audit.attribution;

    for (final entry in _matches(attribution, query)) {
      final suppressed = attribution.suppressed.contains(entry);
      buffer
        ..writeln('${entry.key} — ${attribution.variant}')
        ..writeln();

      if (suppressed) {
        buffer
          ..writeln('  Suppressed: the report records it and the merged '
              'manifest does not hold it.')
          ..writeln();
      }

      _chain(buffer, entry, suppressed: suppressed);
      _rejected(buffer, entry);
      _attributes(buffer, entry);
      _removal(buffer, entry, suppressed: suppressed);
      buffer.writeln();
    }
  }

  return buffer.toString();
}

/// Entries of [attribution] the query names.
///
/// A bare permission name, a suffix such as `AD_ID`, and a component key all
/// work.
List<AttributedEntry> _matches(Attribution attribution, String query) {
  final all = <AttributedEntry>[
    ...attribution.permissions,
    ...attribution.components,
    ...attribution.suppressed,
  ];

  final exact = <AttributedEntry>[
    for (final entry in all)
      if (entry.key == query) entry,
  ];
  if (exact.isNotEmpty) return exact;

  final lower = query.toLowerCase();

  return <AttributedEntry>[
    for (final entry in all)
      if (entry.key.toLowerCase().contains(lower)) entry,
  ];
}

/// Lists the owners of [entry].
///
/// The app's line of a [suppressed] entry is its `tools:node="remove"`, which
/// the merger logs as a declaration.
void _chain(
  StringBuffer buffer,
  AttributedEntry entry, {
  required bool suppressed,
}) {
  final artifacts = <String>{};
  final seen = <String>{};

  for (final record in entry.owners) {
    final owner = record.owner;

    if (owner is ArtifactOwner) {
      artifacts.add(owner.artifact.toString());
      continue;
    }

    if (!seen.add(owner.label)) continue;

    final role = suppressed && owner is AppOwner
        ? 'removed by the app with tools:node="remove"'
        : _role(owner);
    buffer.writeln(_line(_title(owner), role));
    _source(buffer, owner, record.provenance);
  }

  if (artifacts.isEmpty) return;

  final sorted = artifacts.toList()..sort();
  buffer.writeln('  Maven artifacts (${sorted.length}):');
  for (final artifact in sorted) {
    buffer.writeln('    $artifact');
  }
  buffer.writeln(
    '  Which package pulled them in is not in the report; '
    '"gradlew :app:dependencies" in android/ shows it.',
  );
}

void _source(StringBuffer buffer, ResolvedOwner owner, Provenance provenance) {
  final position = provenance.position;
  final at = position == null ? '' : ':${position.line}';

  if (owner is PluginOwner) {
    final source = owner.source;
    if (source != null) {
      buffer.writeln('    $source');
      return;
    }
  }

  if (owner is GradleOwner) {
    buffer.writeln('    Written from the Gradle DSL, not from a manifest.');
    return;
  }

  buffer.writeln('    ${relativeManifestPath(provenance.path)}$at');
}

void _rejected(StringBuffer buffer, AttributedEntry entry) {
  if (entry.rejected.isEmpty) return;

  final owners = <String>{
    for (final record in entry.rejected) _title(record.owner),
  }.toList()
    ..sort();

  buffer
    ..writeln()
    ..writeln('  Also declared it and lost to a higher-priority manifest '
        '(${owners.length}):');
  for (final owner in owners) {
    buffer.writeln('    $owner');
  }
}

/// Lists the attributes whose owner is not an owner of the node.
///
/// The rest are noise: an attribute written by whoever wrote the node says
/// nothing. What is worth printing is a `maxSdkVersion` on a permission the app
/// declared itself, which is a plugin editing your node.
void _attributes(StringBuffer buffer, AttributedEntry entry) {
  final mine = entry.labels.toSet();
  final written = <String, List<String>>{};

  for (final attribute in entry.attributes) {
    final owners = <String>{
      for (final record in attribute.owners)
        if (!mine.contains(record.owner.label)) record.owner.label,
    }.toList()
      ..sort();
    if (owners.isEmpty) continue;

    written[attribute.name] = owners;
  }
  if (written.isEmpty) return;

  buffer
    ..writeln()
    ..writeln('  Attributes written by someone other than the owners above:');
  final names = written.keys.toList()..sort();
  for (final name in names) {
    buffer.writeln(_line(name, written[name]!.join(', '), indent: '    '));
  }
}

void _removal(
  StringBuffer buffer,
  AttributedEntry entry, {
  required bool suppressed,
}) {
  if (suppressed) return;

  final hash = entry.key.indexOf('#');
  final element = hash == -1 ? 'uses-permission' : entry.key.substring(0, hash);
  final name = hash == -1 ? entry.key : entry.key.substring(hash + 1);
  final parent = ManifestNodes.permissionElements.contains(element)
      ? 'manifest'
      : 'application';

  buffer.writeln();
  if (entry.declaredByApp &&
      entry.owners.every((record) => record.owner is AppOwner)) {
    buffer
      ..writeln('  Declared in android/app/src, so dropping it is an edit of')
      ..writeln('  your own manifest rather than a tools:node="remove".');
    return;
  }

  if (entry.declaredByApp) {
    buffer
      ..writeln('  Declared in android/app/src and by a library as well. To')
      ..writeln('  drop it, replace your own line with:');
  } else {
    buffer.writeln('  Not declared in android/app/src. To drop it:');
  }

  buffer
    ..writeln('    <$element android:name="$name"')
    ..writeln('        tools:node="remove" />')
    ..writeln('  as a direct child of <$parent> in '
        'android/app/src/main/AndroidManifest.xml.');
}

String _title(ResolvedOwner owner) => switch (owner) {
      PluginOwner(:final package, :final version) =>
        version == null ? package : '$package $version',
      ModuleOwner(:final name) => ':$name',
      ArtifactOwner(:final artifact) => artifact.toString(),
      _ => owner.label,
    };

String _role(ResolvedOwner owner) => switch (owner) {
      PluginOwner(:final via, :final devDependency) => <String>[
          if (via.isEmpty) 'direct dependency' else 'via ${via.join(', ')}',
          if (devDependency) 'dev dependency, not in release',
        ].join(', '),
      ModuleOwner() => 'local Gradle module',
      AppOwner() => 'declared by the app',
      GradleOwner() => 'the Gradle DSL',
      ArtifactOwner() => 'Maven artifact',
    };

/// Who removed a suppressed entry and who asked for it.
///
/// The merger logs the app's `tools:node="remove"` line as a declaration, so
/// the app's own source sets are the ones that removed it.
String _suppression(AttributedEntry entry) {
  final app = <String>{
    for (final record in entry.owners)
      if (record.owner is AppOwner) record.owner.label,
  };
  final removed = <String>[
    for (final label in entry.labels)
      if (app.contains(label)) label,
  ];
  final wanted = <String>[
    for (final label in entry.labels)
      if (!app.contains(label)) label,
  ];

  return <String>[
    if (removed.isNotEmpty) 'removed by ${removed.join(', ')}',
    if (wanted.isNotEmpty) 'wanted by ${wanted.join(', ')}',
  ].join('; ');
}

void _entries(
    StringBuffer buffer, String title, List<AttributedEntry> entries) {
  if (entries.isEmpty) return;

  buffer.writeln('$title (${entries.length}):');
  for (final entry in entries) {
    buffer.writeln(_line(entry.key, entry.labels.join(', ')));
  }
  buffer.writeln();
}

void _warnings(StringBuffer buffer, VariantAudit audit) {
  if (!audit.hasManifest) {
    buffer.writeln(
      'Neither the merged manifest nor the blame file is on disk, so this is '
      'what the merger considered rather than what the app has. A node removed '
      'with tools:node="remove" is listed here as if it shipped.',
    );
  }

  if (audit.staleInputs.isNotEmpty) {
    buffer.writeln(
      'Warning: ${audit.staleInputs.join(', ')} changed after '
      '${audit.report} was written. Build the variant again.',
    );
  }
}

void _unparsed(StringBuffer buffer, Attribution attribution) {
  if (attribution.unparsed == 0) return;

  buffer.writeln(
    '${attribution.unparsed} line(s) of the report matched nothing in the '
    'grammar and were left out.',
  );
}

String _summary(BaselineDiff diff) {
  final applicationId = diff.of(DiffKind.applicationIdChanged).isNotEmpty;
  final added = diff.of(DiffKind.added).length;
  final lost = diff.of(DiffKind.suppressionLost).length;
  final gained = diff.of(DiffKind.ownerAdded).length;
  final dropped = diff.of(DiffKind.ownerRemoved).length;
  final gone = diff.of(DiffKind.removed).length;
  final suppressed = diff.of(DiffKind.suppressionAdded).length;

  final parts = <String>[
    if (applicationId) 'application id changed',
    if (added > 0) _count(added, 'new entry', plural: 'new entries'),
    if (lost > 0) '$lost suppression(s) lost',
    if (gained > 0) '$gained entry(s) with a new owner',
    if (dropped > 0) '$dropped entry(s) with an owner gone',
    if (gone > 0) '${_count(gone, 'entry', plural: 'entries')} gone',
    if (suppressed > 0) '$suppressed newly suppressed',
  ];

  return '${parts.join(', ')}.';
}

/// What the `--strict` hint calls the changes of [kind].
String _changes(DiffKind kind) => switch (kind) {
      DiffKind.added => 'new entries',
      DiffKind.ownerAdded || DiffKind.ownerRemoved => 'owner changes',
      DiffKind.removed => 'removals',
      DiffKind.suppressionLost => 'lost suppressions',
      DiffKind.suppressionAdded => 'new suppressions',
      DiffKind.applicationIdChanged => 'application id changes',
    };

void _diffEntries(StringBuffer buffer, BaselineDiff diff) {
  for (final entry in diff.entries) {
    buffer.writeln(_line('${entry.kind.marker} ${entry.key}', _owners(entry)));
  }
}

String _owners(DiffEntry entry) => switch (entry.kind) {
      DiffKind.ownerAdded => '+ ${entry.owners.join(', ')}',
      DiffKind.ownerRemoved => '- ${entry.owners.join(', ')}',
      DiffKind.applicationIdChanged => entry.owners.join(' → '),
      _ => entry.owners.join(', '),
    };

String _line(String left, String right, {String indent = '  '}) => right.isEmpty
    ? '$indent$left'
    : '$indent${left.padRight(_column - indent.length - 1)} $right';

String _count(int value, String noun, {String? plural}) =>
    '$value ${value == 1 ? noun : plural ?? '${noun}s'}';
