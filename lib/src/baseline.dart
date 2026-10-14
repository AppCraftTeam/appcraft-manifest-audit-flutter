import 'package:yaml/yaml.dart';

import 'attribution.dart';
import 'merged_manifest.dart';

/// What a diff entry says happened.
enum DiffKind {
  /// A permission or component the baseline does not hold.
  added('+'),

  /// An existing entry, present or suppressed, gained a library.
  ownerAdded('~'),

  /// An existing entry, present or suppressed, lost a library.
  ownerRemoved('~'),

  /// An entry the app no longer has, or a suppressed one nothing asks for any
  /// more.
  removed('-'),

  /// A `suppressed` entry of the baseline is present again.
  suppressionLost('!'),

  /// An entry the app suppresses and the baseline does not mention.
  suppressionAdded('x'),

  /// The application id differs from the one the baseline records.
  applicationIdChanged('~');

  const DiffKind(this.marker);

  /// Character the diff prints in front of the entry.
  final String marker;

  /// Whether the kind fails `check` without `--strict`.
  ///
  /// `added` and `suppression lost` are the two that get an app rejected, so
  /// they are the two that fail by default. Owner changes and removals are the
  /// interesting-but-not-urgent category: failing every build on them would
  /// train people to run `baseline` without reading.
  bool get failsByDefault =>
      this == DiffKind.added || this == DiffKind.suppressionLost;
}

/// One difference between the baseline and the current build output.
final class DiffEntry {
  /// Creates an entry.
  const DiffEntry({
    required this.kind,
    required this.key,
    required this.owners,
  });

  /// What happened.
  final DiffKind kind;

  /// Permission name or component key.
  final String key;

  /// Libraries the entry is about: the owners now for an addition, the ones
  /// that appeared or disappeared for an owner change. For a changed
  /// application id, the recorded value and the current one.
  final List<String> owners;
}

/// Everything that changed for one variant.
final class BaselineDiff {
  /// Creates a diff.
  const BaselineDiff({
    required this.variant,
    required this.entries,
  });

  /// Variant the diff is about.
  final String variant;

  /// Differences, in the order they are printed.
  final List<DiffEntry> entries;

  /// Whether there is anything to report.
  bool get isEmpty => entries.isEmpty;

  /// Whether `check` fails on this diff.
  bool fails({required bool strict}) => strict
      ? entries.isNotEmpty
      : entries.any((entry) => entry.kind.failsByDefault);

  /// Entries of [kind].
  List<DiffEntry> of(DiffKind kind) => <DiffEntry>[
        for (final entry in entries)
          if (entry.kind == kind) entry,
      ];
}

/// One variant's section of the baseline.
final class BaselineVariant {
  /// Creates a section.
  const BaselineVariant({
    required this.permissions,
    required this.components,
    required this.suppressed,
    this.applicationId,
  });

  /// Reads the section off an attribution.
  ///
  /// The unattributed entries are recorded too, under an owner that says as
  /// much. They are in the merged manifest, so they ship, and leaving them out
  /// would make a new permission the report cannot explain invisible to
  /// `check` — the one failure the baseline exists to prevent.
  factory BaselineVariant.of(Attribution attribution) => BaselineVariant(
        applicationId: attribution.applicationId,
        permissions: <String, List<BaselineOwner>>{
          ..._owners(attribution.permissions),
          ..._unattributed(attribution.unattributed, components: false),
        },
        components: <String, List<BaselineOwner>>{
          ..._owners(attribution.components),
          ..._unattributed(attribution.unattributed, components: true),
        },
        suppressed: _owners(attribution.suppressed),
      );

  /// Application id of the variant.
  ///
  /// Recorded because the merger substitutes it into permission names, so the
  /// same node has a different name per flavour and the baseline keys on the
  /// placeholder form instead.
  final String? applicationId;

  /// Permissions of the merged manifest, keyed by name.
  final Map<String, List<BaselineOwner>> permissions;

  /// Components of the merged manifest, keyed by `<element>#<name>`.
  final Map<String, List<BaselineOwner>> components;

  /// Entries the report records and the merged manifest drops.
  final Map<String, List<BaselineOwner>> suppressed;

  static Map<String, List<BaselineOwner>> _owners(
    List<AttributedEntry> entries,
  ) =>
      <String, List<BaselineOwner>>{
        for (final entry in entries) entry.key: entry.baselineOwners,
      };

  static Map<String, List<BaselineOwner>> _unattributed(
    List<String> names, {
    required bool components,
  }) =>
      <String, List<BaselineOwner>>{
        for (final name in names)
          if (ManifestNodes.componentElements.contains(name.split('#').first) ==
              components)
            name: const <BaselineOwner>[
              BaselineOwner(key: 'unattributed', note: 'no node in the report'),
            ],
      };
}

/// The committed answer, against which the current build output is compared.
///
/// YAML rather than JSON because the file is read in a pull request: the whole
/// point is that a reviewer sees `com.google.android.gms.permission.AD_ID`
/// appear under `appsflyer_sdk` in a diff and asks about it. Keys are sorted,
/// so the diff is minimal and stable.
final class Baseline {
  /// Creates a baseline.
  const Baseline(this.variants);

  /// Reads a baseline file.
  ///
  /// Throws a [BaselineException] when the file is not a baseline of a version
  /// this package knows.
  factory Baseline.parse(String content) {
    final Object? document;
    try {
      document = loadYaml(content);
    } on YamlException catch (e) {
      throw BaselineException('The baseline is not valid YAML.\n$e');
    }
    if (document == null) return const Baseline(<String, BaselineVariant>{});

    if (document is! YamlMap) {
      throw const BaselineException('The baseline is not a YAML mapping.');
    }

    final version = document['version'];
    if (version != formatVersion) {
      throw BaselineException(
        'The baseline says version $version, and this package writes version '
        '$formatVersion. Regenerate it with '
        '"dart run appcraft_manifest_audit baseline".',
      );
    }

    final variants = document['variants'];
    if (variants is! YamlMap) {
      return const Baseline(<String, BaselineVariant>{});
    }

    return Baseline(<String, BaselineVariant>{
      for (final entry in variants.entries)
        if (entry.key case final String variant)
          variant: _variantOf(variant, entry.value),
    });
  }

  /// Builds a baseline out of the audits of one run.
  factory Baseline.of(Iterable<Attribution> attributions) =>
      Baseline(<String, BaselineVariant>{
        for (final attribution in attributions)
          attribution.variant: BaselineVariant.of(attribution),
      });

  /// Sections by variant name.
  final Map<String, BaselineVariant> variants;

  /// Format version the file carries.
  static const int formatVersion = 1;

  /// Renders the file, keys sorted.
  String render() {
    final buffer = StringBuffer()
      ..writeln('# Generated by appcraft_manifest_audit.')
      ..writeln('# Update with: dart run appcraft_manifest_audit baseline')
      ..writeln('version: $formatVersion')
      ..writeln('variants:');

    final names = variants.keys.toList()..sort();
    for (final name in names) {
      final variant = variants[name]!;
      buffer.writeln('  ${_scalar(name)}:');

      final applicationId = variant.applicationId;
      if (applicationId != null) {
        buffer.writeln('    application-id: ${_scalar(applicationId)}');
      }

      _section(buffer, 'permissions', variant.permissions);
      _section(buffer, 'components', variant.components);
      _section(buffer, 'suppressed', variant.suppressed);
    }

    return buffer.toString();
  }

  /// Compares [current] against the section of its variant.
  ///
  /// A variant the baseline does not hold is compared against an empty section,
  /// so every entry of a new variant is an addition.
  BaselineDiff diff(Attribution current) {
    final known = variants[current.variant];
    final recorded = known ??
        const BaselineVariant(
          permissions: <String, List<BaselineOwner>>{},
          components: <String, List<BaselineOwner>>{},
          suppressed: <String, List<BaselineOwner>>{},
        );

    // Compared through the same view the file is written from, so that
    // anything `baseline` would record is something `check` can see change.
    final now = BaselineVariant.of(current);

    final entries = <DiffEntry>[];
    final present = <String, List<BaselineOwner>>{
      ...now.permissions,
      ...now.components,
    };
    final was = <String, List<BaselineOwner>>{
      ...recorded.permissions,
      ...recorded.components,
    };
    final suppressed = now.suppressed;

    if (known != null && known.applicationId != now.applicationId) {
      entries.add(DiffEntry(
        kind: DiffKind.applicationIdChanged,
        key: 'application-id',
        owners: <String>[
          known.applicationId ?? 'none',
          now.applicationId ?? 'none',
        ],
      ));
    }

    for (final key in _sorted(present.keys)) {
      final owners = present[key]!;
      final before = was[key];

      if (before == null) {
        entries.add(DiffEntry(
          kind: recorded.suppressed.containsKey(key)
              ? DiffKind.suppressionLost
              : DiffKind.added,
          key: key,
          owners: _keys(owners),
        ));
        continue;
      }

      _ownerChanges(entries, key, owners, before);
    }

    for (final key in _sorted(was.keys)) {
      if (present.containsKey(key)) continue;

      entries.add(DiffEntry(
        kind: DiffKind.removed,
        key: key,
        owners: _keys(was[key]!),
      ));
    }

    for (final key in _sorted(suppressed.keys)) {
      if (was.containsKey(key)) continue;

      final before = recorded.suppressed[key];
      if (before == null) {
        entries.add(DiffEntry(
          kind: DiffKind.suppressionAdded,
          key: key,
          owners: _keys(suppressed[key]!),
        ));
        continue;
      }

      _ownerChanges(entries, key, suppressed[key]!, before);
    }

    for (final key in _sorted(recorded.suppressed.keys)) {
      if (present.containsKey(key) || suppressed.containsKey(key)) continue;

      entries.add(DiffEntry(
        kind: DiffKind.removed,
        key: key,
        owners: _keys(recorded.suppressed[key]!),
      ));
    }

    return BaselineDiff(variant: current.variant, entries: entries);
  }

  /// Appends the libraries [key] gained and lost between [before] and [now].
  static void _ownerChanges(
    List<DiffEntry> entries,
    String key,
    List<BaselineOwner> now,
    List<BaselineOwner> before,
  ) {
    final gained = _difference(now, before);
    if (gained.isNotEmpty) {
      entries.add(DiffEntry(
        kind: DiffKind.ownerAdded,
        key: key,
        owners: gained,
      ));
    }

    final lost = _difference(before, now);
    if (lost.isNotEmpty) {
      entries.add(DiffEntry(
        kind: DiffKind.ownerRemoved,
        key: key,
        owners: lost,
      ));
    }
  }

  static void _section(
    StringBuffer buffer,
    String name,
    Map<String, List<BaselineOwner>> entries,
  ) {
    if (entries.isEmpty) return;

    buffer.writeln('    $name:');
    for (final key in _sorted(entries.keys)) {
      buffer.writeln('      ${_scalar(key)}:');
      for (final owner in entries[key]!) {
        final line = '        - ${_scalar(owner.key)}';
        final note = owner.note;
        buffer.writeln(
          note == null ? line : '${line.padRight(35)} # $note',
        );
      }
    }
  }

  static BaselineVariant _variantOf(String variant, Object? section) {
    if (section is! YamlMap) {
      throw BaselineException('Variant "$variant" is not a mapping.');
    }

    return BaselineVariant(
      applicationId: switch (section['application-id']) {
        null => null,
        final String applicationId => applicationId,
        final other => throw BaselineException(
            'The application-id of variant "$variant" is not a string, got '
            '"$other".',
          ),
      },
      permissions: _entriesOf(variant, section['permissions']),
      components: _entriesOf(variant, section['components']),
      suppressed: _entriesOf(variant, section['suppressed']),
    );
  }

  static Map<String, List<BaselineOwner>> _entriesOf(
    String variant,
    Object? section,
  ) {
    if (section == null) return <String, List<BaselineOwner>>{};

    if (section is! YamlMap) {
      throw BaselineException('A section of variant "$variant" is not a '
          'mapping of entries to their owners.');
    }

    return <String, List<BaselineOwner>>{
      for (final entry in section.entries)
        if (entry.key case final String key)
          key: <BaselineOwner>[
            if (entry.value case final YamlList owners)
              for (final owner in owners)
                if (owner is String) BaselineOwner(key: owner),
          ],
    };
  }

  static List<String> _keys(List<BaselineOwner> owners) =>
      <String>[for (final owner in owners) owner.key];

  static List<String> _difference(
    List<BaselineOwner> from,
    List<BaselineOwner> other,
  ) {
    final known = <String>{for (final owner in other) owner.key};

    return <String>[
      for (final owner in from)
        if (!known.contains(owner.key)) owner.key,
    ];
  }

  static List<String> _sorted(Iterable<String> values) {
    final sorted = values.toList()..sort();

    return sorted;
  }

  /// Quotes a scalar that YAML would read as something else.
  static String _scalar(String value) =>
      _plain.hasMatch(value) ? value : "'${value.replaceAll("'", "''")}'";

  static final RegExp _plain = RegExp(r'^[A-Za-z0-9_$][A-Za-z0-9_.\-${}/#:]*$');
}

/// Thrown when the baseline file cannot be read.
final class BaselineException implements Exception {
  /// Creates an exception carrying a message meant for the user.
  const BaselineException(this.message);

  /// What is wrong with the file.
  final String message;

  @override
  String toString() => message;
}
