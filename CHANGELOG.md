## 0.0.1

- Attribution of every `<uses-permission>` and component of the merged Android
  manifest to the library that injected it, read from the manifest merger's
  decision tree log.
- The merged manifest is the authority for what the app has and the report for
  who wanted it, so a node dropped by `tools:node="remove"` is reported as
  suppressed instead of as shipped. The merger's blame file stands in when the
  merged manifest is not on disk, and a run without either says so and refuses
  to write a baseline.
- A Gradle subproject is attributed to its pub package, and a Maven artifact to
  itself as `group:artifact`: the report does not say which package pulled an
  artifact in, so the tool names the artifact rather than guessing at a plugin.
- `<uses-permission-sdk-23>` entries are read too, keyed as
  `uses-permission-sdk-23#<name>` apart from a `<uses-permission>` of the same
  name.
- A federated implementation is named along with the package a pubspec declares
  — `camera_android_camerax (via camera)`.
- `report`, `check` for CI, `baseline` with `--dry-run`, and `explain <name>`
  with the chain of libraries and the removal snippet.
- A baseline per variant at `android/manifest_audit.yaml`, sorted for a readable
  pull request diff, keyed on the `${applicationId}` placeholder so two flavours
  record the same node once.
- New entries and lost suppressions fail `check`; owner changes, removals,
  changes to the suppressed set and a changed application id are reported and
  fail only under `--strict`.
- A baseline or a `pubspec.yaml` that does not parse stops the run with 64 and a
  message naming the file.
- Discovery rather than templating: the reports, merged manifests and blame
  files are globbed from a bounded set of roots, which survives the AGP 7 to 8
  path change and Flutter's build-directory redirection. The newest wins when
  two layouts sit on disk at once.
- A freshness guard against `pubspec.lock`, the app module's build script and
  the source-set manifests of the variant, so a report that outlived the change
  that invalidates it warns in `report` and stops `check` and `baseline`.
- Lines the grammar does not match are counted as `unparsed` rather than waved
  through, and a permission in the manifest with no node in the report is
  recorded as `unattributed` in the output and in the baseline both.
