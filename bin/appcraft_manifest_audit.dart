import 'dart:io';

import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

/// Version of the package, kept in step with `pubspec.yaml`.
const String _version = '0.0.1';

const String _usageHeader = '''
Attributes every permission and component of the merged Android manifest to the
library that injected it.

Usage: appcraft_manifest_audit <command> [options]

Commands:
  report            list every permission and component with its owners
  check             exit with 1 if the build output differs from the baseline (for CI)
  baseline          write the baseline from the current build output
  explain <name>    print the libraries responsible for one permission or component
''';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addMultiOption(
      'variant',
      help: 'Variant to audit; default is the configured variants, else every '
          'variant found on disk, or for check every variant the baseline '
          'names.',
    )
    ..addOption(
      'baseline',
      help: 'Path of the baseline file.',
    )
    ..addOption(
      'build',
      help: "Root of the Android module's build outputs.",
    )
    ..addOption(
      'report',
      help: 'Path of a merger report, bypassing the discovery.',
    )
    ..addOption(
      'merged-manifest',
      help: 'Path of a merged manifest, bypassing the discovery.',
    )
    ..addFlag(
      'strict',
      negatable: false,
      help: 'For check: every difference fails, not only new entries and lost '
          'suppressions.',
    )
    ..addFlag(
      'dry-run',
      negatable: false,
      help: 'For baseline: print the diff, write nothing.',
    )
    ..addFlag(
      'version',
      negatable: false,
      help: 'Print the version and exit.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
    );

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (e) {
    _fail('${e.message}\n\n$_usageHeader${parser.usage}');
  }

  if (options['version'] as bool) {
    stdout.writeln(_version);
    return;
  }

  if (options['help'] as bool || options.rest.isEmpty) {
    stdout.writeln('$_usageHeader\n${parser.usage}');
    return;
  }

  try {
    _run(options);
  } on ManifestAuditConfigException catch (e) {
    _fail(e.message);
  } on BuildOutputException catch (e) {
    _fail(e.message);
  }
}

void _run(ArgResults options) {
  final command = options.rest.first;
  final root = Directory.current.path;
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    _fail('pubspec.yaml not found in $root.');
  }

  final fromFile = ManifestAuditConfig.fromPubspec(pubspec.readAsStringSync());
  final config = ManifestAuditConfig(
    baseline: options['baseline'] as String? ?? fromFile.baseline,
    build: options['build'] as String? ?? fromFile.build,
    variants: fromFile.variants,
    ignore: fromFile.ignore,
  )..validate();

  final auditor = ManifestAuditor(
    root: root,
    config: config,
    reportOverride: options['report'] as String?,
    mergedManifestOverride: options['merged-manifest'] as String?,
  );
  final requested = options['variant'] as List<String>;
  final baseline = File(p.join(root, config.baseline));

  switch (command) {
    case 'report':
      _report(auditor.select(requested).map(auditor.audit).toList());
    case 'check':
      _check(
        auditor: auditor,
        baseline: baseline,
        requested: requested,
        strict: options['strict'] as bool,
      );
    case 'baseline':
      _baseline(
        auditor: auditor,
        file: baseline,
        requested: requested,
        dryRun: options['dry-run'] as bool,
      );
    case 'explain':
      _explain(
        audits: auditor.select(requested).map(auditor.audit).toList(),
        query: options.rest.length > 1 ? options.rest[1] : null,
      );
    default:
      _fail('Unknown command "$command".\n\n$_usageHeader');
  }
}

void _report(List<VariantAudit> audits) {
  for (final audit in audits) {
    stdout.write(renderReport(audit));
    if (audit != audits.last) stdout.writeln();
  }
}

void _check({
  required ManifestAuditor auditor,
  required File baseline,
  required List<String> requested,
  required bool strict,
}) {
  if (!baseline.existsSync()) {
    _fail(
      'Baseline not found: ${_relative(baseline, auditor)}\n'
      'Write it with "dart run appcraft_manifest_audit baseline" and commit it.',
    );
  }

  final recorded = _readBaseline(baseline, auditor);
  final variants = requested.isEmpty && auditor.config.variants.isEmpty
      ? recorded.variants.keys.toList()
      : requested;

  final audits = _audits(auditor, variants, 'check');
  var failed = false;
  var differs = false;

  for (final audit in audits) {
    final diff = recorded.diff(audit.attribution);
    final rendered = renderCheck(diff, strict: strict);
    if (rendered.isEmpty) continue;

    stderr.write(rendered);
    differs = true;
    failed |= diff.fails(strict: strict);
  }

  if (failed) exit(1);
  if (differs) return;

  stdout.writeln(
    'The merged manifest matches the baseline for ${_variants(audits)}.',
  );
}

void _baseline({
  required ManifestAuditor auditor,
  required File file,
  required List<String> requested,
  required bool dryRun,
}) {
  final audits = _audits(auditor, requested, 'baseline');
  final recorded = file.existsSync()
      ? _readBaseline(file, auditor)
      : const Baseline(<String, BaselineVariant>{});

  if (dryRun) {
    for (final audit in audits) {
      stdout.write(renderBaselineDiff(recorded.diff(audit.attribution)));
    }
    return;
  }

  // Variants this run did not audit keep the answer they had: a project that
  // ships two flavours would otherwise lose one of them to a single-variant
  // run.
  final written = Baseline(<String, BaselineVariant>{
    ...recorded.variants,
    for (final audit in audits)
      audit.attribution.variant: BaselineVariant.of(audit.attribution),
  });

  file.parent.createSync(recursive: true);
  file.writeAsStringSync(written.render());

  stdout.writeln(
    'Wrote ${_relative(file, auditor)} for ${_variants(audits)}. '
    'Commit it — the reviewer of that commit is the approval mechanism.',
  );
}

void _explain({
  required List<VariantAudit> audits,
  required String? query,
}) {
  if (query == null) {
    _fail(
      'explain needs a name.\n'
      '  dart run appcraft_manifest_audit explain AD_ID',
    );
  }

  final rendered = renderExplain(audits, query);
  if (rendered.trim().isEmpty) {
    _fail(
      'Nothing matching "$query" in ${_variants(audits)}.\n'
      'Run "dart run appcraft_manifest_audit report" for the full list.',
    );
  }

  stdout.write(rendered);
}

/// Audits the variants, refusing when the run knows too little to be trusted.
///
/// A baseline built from an uncorrected report is worse than no baseline: the
/// report records the nodes the merger considered, and a `tools:node="remove"`
/// is among them. And a report that outlived the change that invalidates it
/// would let a `check` pass a build nobody made.
List<VariantAudit> _audits(
  ManifestAuditor auditor,
  List<String> requested,
  String command,
) {
  final audits = auditor.select(requested).map(auditor.audit).toList();

  for (final audit in audits) {
    if (!audit.hasManifest) {
      _fail(
        'No merged manifest and no blame file for '
        '${audit.attribution.variant}, so ${audit.report} cannot be corrected '
        'for the nodes it lists and the merger dropped.\n'
        'Build the variant again, or point at the manifest with '
        '--merged-manifest.',
      );
    }

    if (audit.staleInputs.isNotEmpty) {
      _fail(
        '${audit.staleInputs.join(', ')} changed after ${audit.report} was '
        'written, so $command would answer for a build that no longer exists.\n'
        'Build the variant again.',
      );
    }
  }

  return audits;
}

/// Reads the baseline [file], stopping with 64 when it is not one.
Baseline _readBaseline(File file, ManifestAuditor auditor) {
  try {
    return Baseline.parse(file.readAsStringSync());
  } on BaselineException catch (e) {
    _fail('${_relative(file, auditor)}: ${e.message}');
  }
}

String _relative(File file, ManifestAuditor auditor) =>
    p.relative(file.path, from: auditor.root).replaceAll(r'\', '/');

String _variants(List<VariantAudit> audits) =>
    audits.map((audit) => audit.attribution.variant).join(', ');

Never _fail(String message) {
  stderr.writeln(message);
  exit(64);
}
