# appcraft_manifest_audit

[![Pub Version](https://img.shields.io/pub/v/appcraft_manifest_audit)](https://pub.dev/packages/appcraft_manifest_audit)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Says which library put each permission into your Android app, and fails CI when
the answer changes.

## Why

Flutter plugins inject `<uses-permission>` entries, services, receivers and
providers into the merged manifest. Google Play rejects apps over camera and
media permissions nobody on the team wrote, because they contradict the Data
Safety declaration — and finding the dependency that brought one in is
guesswork. In [one such report][case] the `READ_MEDIA_IMAGES` and
`READ_MEDIA_VIDEO` behind a rejection turned out, after a search by hand, to
come from `open_filex`.

The answer exists on disk. Gradle writes a merging decision tree log while it
builds, at `build/app/outputs/logs/manifest-merger-<variant>-report.txt` — a one
to three thousand line file where every provenance line is repeated twice and
the paths run to two hundred characters. This tool reads it, maps every entry to
the pub package or Maven artifact behind it, and freezes the result in a
baseline you commit.

Android Studio's *Merged Manifest* tab attributes nodes too, but only inside
the IDE and one variant at a time. `aapt2 dump permissions` and
`bundletool dump manifest` read a built APK, where the link between a node and
the dependency behind it is already gone.

[case]: https://github.com/flutter/flutter/issues/158315

## Requirements

**The variant has to have been built.** The tool reads files Gradle wrote; it
never runs Gradle itself, needs no JDK, no Android SDK and no network, and it
runs anywhere `dart` runs. On CI that costs nothing — `check` goes in the same
job as `flutter build`, after it. Locally it means a first run without a build
gets an error rather than an answer:

```console
$ dart run appcraft_manifest_audit check --variant prod-release
No merger report found for variant "prod-release".
Found reports for: prod-debug, beta-debug

Build the variant first:
  flutter build apk --release --flavor prod
```

## Installation

```yaml
dev_dependencies:
  appcraft_manifest_audit: ^0.0.1
```

## Usage

**Audit the variant you upload, not the one you run.** Flutter's own
`android/app/src/debug/AndroidManifest.xml` declares `INTERNET` for hot reload,
and modern Flutter leaves dev-dependency plugins out of release builds — so a
debug audit lists permissions that never ship and a release audit is the one
Play sees.

```bash
dart run appcraft_manifest_audit report --variant prod-release
```

| Command | What it does |
|---|---|
| `report` | lists every permission and component with the libraries behind it |
| `check` | exits with 1 when the build output differs from the baseline — for CI |
| `baseline` | writes the baseline from the current build output |
| `explain <name>` | prints the chain of libraries responsible for one entry |

| Option | Meaning |
|---|---|
| `--variant` | variant to audit, repeatable; default is the configured `variants`, else every variant on disk — for `check`, every variant the baseline names |
| `--baseline` | path of the baseline file, overriding the configuration |
| `--build` | root of the Android build outputs, overriding the discovery |
| `--report` | path of a merger report, bypassing the discovery |
| `--merged-manifest` | path of a merged manifest, bypassing the discovery |
| `--strict` | for `check`: every difference fails, not only new entries and lost suppressions |
| `--dry-run` | for `baseline`: print the diff, write nothing |

`--version` prints the version. Exit codes: 1 when a command found something
wrong, 64 when the invocation, the configuration or the build output is wrong.

```console
$ dart run appcraft_manifest_audit report
debug — 6 permission(s), 3 component(s)

Permissions the app declares itself (2):
  android.permission.INTERNET                          app/src/debug, app/src/main
  android.permission.READ_EXTERNAL_STORAGE             app/src/main

Permissions injected by libraries (4):
  android.permission.ACCESS_ADSERVICES_AD_ID           androidx.privacysandbox.ads:ads-adservices
  android.permission.RECORD_AUDIO                      camera_android_camerax (via camera)
  android.permission.VIBRATE                           vibration
  android.permission.WAKE_LOCK                         com.google.firebase:firebase-messaging

In the manifest with no node in the report (1):
  android.permission.POST_NOTIFICATIONS                unattributed

Components: 3, from 4 libraries. Run "explain" for one of them.
```

Grouping by *who* rather than by *what* is the whole readability win over the
raw log: the developer scans the second block, and everything in it is a
candidate for a Data Safety question.

## Removing a permission you do not want

Once `report` has named the library, the permission is taken out in your own
`android/app/src/main/AndroidManifest.xml`, as a direct child of `<manifest>`,
with the `tools` namespace declared on it:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission
        android:name="android.permission.READ_MEDIA_IMAGES"
        tools:node="remove" />
```

The library still asks for it, so whatever in that library needs the permission
stops working. `explain <name>` shows the chain of libraries behind it — check
that the app does not use that part before removing it.

If `report` lists the permission among those the app declares itself and also
names a library, replace your own `<uses-permission>` line with the
`tools:node="remove"` one: deleting yours leaves the library's in place.

A library's `<uses-permission-sdk-23>` is a node of its own, listed as
`uses-permission-sdk-23#<name>`, and the line above does not touch it. It needs
its own removal, on that element:

```xml
    <uses-permission-sdk-23
        android:name="android.permission.READ_MEDIA_IMAGES"
        tools:node="remove" />
```

Then rebuild the variant and run `baseline`: the permission moves to
`suppressed`, and `check` fails the day it reaches the merged manifest again —
the removal line dropped in a merge, or moved where it has no effect.

## How a node becomes a package name

**A Gradle subproject is a pub package.** Flutter's plugin loader includes
`:${plugin.name}` and points it at the package directory, so `[:share_plus]` in
the log *is* the package `share_plus`, with no transformation.
`.flutter-plugins-dependencies` confirms it and gives the version for free. Its
`dependencyGraph` gives one more thing that matters: a federated implementation
is reported as `camera_android_camerax (via camera)`, because `camera` is what
the pubspec says and what the developer can act on.

**A Maven artifact is named as itself.** The app-level log says an AAR
contributed the node and nothing about who pulled the AAR in, and a plugin's own
report does not say either: AGP merges a library's manifest without its
dependencies. So the owner is the artifact, `group:artifact` —
`com.google.firebase:firebase-messaging` rather than `firebase_messaging` — and
`explain` adds the version. The plugin behind it is one Gradle command away:

```bash
cd android && ./gradlew :app:dependencies --configuration releaseRuntimeClasspath
```

The tool does not run it and does not guess at the nearest plausible plugin. An
artifact is a first-class owner in the output and in the baseline, never an
empty owner list that reads as "nobody".

## The report is not the answer — the merged manifest is

This is the rule the whole package turns on, and it is why both files are read.

A project that removes a permission in its own manifest:

```xml
<uses-permission
    android:name="android.permission.READ_MEDIA_IMAGES"
    tools:node="remove" />
```

still gets `ADDED from …\src\main\AndroidManifest.xml` in the log, while the
merged manifest contains no such permission at all. The log records decisions
*considered*, not results. A tool that read only the log would tell a team they
ship `READ_MEDIA_IMAGES` when they do not.

So the merged manifest is the authority for what the app has, the report is the
authority for who wanted it, and the difference between them is the `suppressed`
set. When the merged manifest is missing, the merger's blame file stands in for
it — it reflects the final manifest and answers the same question. When neither
is there, `report` still attributes but says in its first line that it is
listing what the merger considered, and `check` and `baseline` refuse with 64: a
baseline built from an uncorrected report is worse than no baseline.

## The baseline

`baseline` writes `android/manifest_audit.yaml`, and you commit it.

```yaml
# Generated by appcraft_manifest_audit.
# Update with: dart run appcraft_manifest_audit baseline
version: 1
variants:
  prod-release:
    application-id: com.demoshop
    permissions:
      android.permission.INTERNET:
        - app/src/main
      android.permission.WAKE_LOCK:
        - com.google.firebase:firebase-messaging
      com.google.android.gms.permission.AD_ID:
        - com.appsflyer:af-android-sdk
        - com.google.android.gms:play-services-ads-identifier
    components:
      provider#androidx.startup.InitializationProvider:
        - androidx.startup:startup-runtime
        - firebase_core
    suppressed:
      android.permission.READ_MEDIA_IMAGES:
        - app/src/main
        - open_filex
```

A `suppressed` entry lists `app/src/main` next to the library that asked for
the permission: the merger logs your `tools:node="remove"` line as a declaration
of the app, and `report` prints it as `removed by app/src/main; wanted by
open_filex`.

YAML rather than JSON because the file is read in a pull request: the point is
that a reviewer sees `AD_ID` appear under an ad SDK in a diff and asks about it.
Keys are sorted, so the diff is minimal.

| Category | Meaning | Fails `check` |
|---|---|---|
| added | a permission or component the baseline does not hold | yes |
| suppression lost | a `suppressed` entry is present again | yes |
| owner added | an existing entry, present or suppressed, gained a library | `--strict` |
| owner removed | an existing entry, present or suppressed, lost a library | `--strict` |
| removed | an entry the app no longer has, or a suppressed one nothing asks for any more | `--strict` |
| newly suppressed | an entry the app suppresses and the baseline does not mention | `--strict` |
| application id changed | the variant's application id differs from the recorded one | `--strict` |
| variant missing | the baseline names a variant with no report | exit 64 |

`added` and `suppression lost` are the two that get an app rejected, so they are
the two that fail by default. Failing every build on an owner change would train
people to run `baseline` without reading it; `--strict` is for teams that want
it hard.

Updating is the same command. There is no `--accept-new` and no per-entry
approval: see the diff in `check`, decide, run `baseline`, and the decision is
in the commit. The reviewer of that commit is the approval mechanism, which is
the only one that has ever worked for this class of file.

`baseline` keeps the variants a run did not audit, so a single-variant run in a
flavoured project does not drop the others.

## Configuration

Optional. Every default is discovery, so a normal Flutter project configures
nothing:

```yaml
appcraft_manifest_audit:
  baseline: android/manifest_audit.yaml
  build: build/app
  variants:
    - prod-release
  ignore:
    - android.permission.INTERNET
```

`build` exists because Flutter's build-directory redirection is a moving target
and a monorepo may put the outputs anywhere; leaving it unset means "find them".
`variants` narrows what `report` and `check` audit when no `--variant` is given.
An `ignore` entry covers the exact name and nothing else — unlike the
path-prefix `ignore` of `appcraft_unused_assets`, because a permission name is
not a path and a prefix match on `android.permission.READ_` would be a footgun.

## The format is undocumented, and that is permanent

Google documents *where* the report is and says nothing at all about what is
inside it — not the verbs, not the owner brackets, not the position format. The
syntax is an implementation detail of the merger that happens to be stable, and
treating it as a contract would be a lie. It is pinned here by recorded fixtures
rather than by a specification, which is this package's standing maintenance
burden.

The failure mode is designed for. A line that matches nothing lands in an
`unparsed` count printed at the end of `report` and `check`, and an unknown verb
goes there too rather than through a permissive catch-all. If nothing at all
parses, the run stops with 64, prints the first lines of the file and points at
`--merged-manifest`, which still gives the unattributed permission list — a
worse answer, but the right one.

## Where it is wrong

**A `tools:node="remove"` in the wrong place does nothing, and the tool will not
tell you.** A `uses-permission` is only meaningful as a direct child of
`<manifest>`; one nested inside an `<activity>` is silently ignored — no error,
no warning, no effect. The tool correctly reports the permission as present and
does not explain that a removal was attempted and missed.

**The debug build type adds a permission nobody wrote.** Flutter's
`src/debug/AndroidManifest.xml` ships `INTERNET` for hot reload. Auditing
`debug` reports something that never ships. Labelling the source set mitigates
it; auditing the release variant solves it.

**Dev-dependency plugins are in debug and not in release.** A debug baseline
lists permissions the release build does not have, so a `check` against the
wrong variant is confidently wrong in both directions.

**Implied permissions are handled but untested against reality.** A dependency
with a low enough `targetSdkVersion` makes the merger add `WRITE_EXTERNAL_STORAGE`
or `READ_PHONE_STATE` on its behalf; those arrive as `IMPLIED from` with a fixed
reason string. No project available while this package was written targets low
enough to produce one, so that branch is exercised by a hand-written fixture
only. If the format has drifted, such lines land in `unparsed` rather than being
mis-attributed — the right failure, but a failure.

**`REJECTED from` means the opposite of what it looks like.** Two libraries
declared the same component and one won. The rejected library still *wanted* it,
so it belongs in `explain` and not in the owner list of `report`. The two
outputs deliberately disagree here.

**The owner of an attribute is not the owner of the node.** A permission you
declared yourself can carry an `android:maxSdkVersion` a plugin wrote. Play
reads the node, so the baseline records node owners only; the attribute owners
are in `explain`.

**`queries` is summarised, not listed.** A release report can hold two hundred
`<package>` entries from one payment SDK, which would bury the twenty entries
that matter. A single new `<package>` is therefore invisible in `report`.

**An `INJECTED` line names a file that does not contain the thing.** AGP writes
`minSdkVersion`, `versionCode` and `android:extractNativeLibs` from the Gradle
DSL and still attributes them to a manifest. Following the cited path leads
nowhere, so the tool renders those as `Gradle (android/app/build.gradle)`. It
affects `uses-sdk` and the attributes of `application`, not permissions.

**A `[:name]` is not always a plugin.** An app with its own Android library
modules shows them exactly like plugins. Unmatched against
`.flutter-plugins-dependencies` they are labelled `local Gradle module`, which
is right and tells you nothing about where in your own codebase to look.

**Two AGP output layouts coexist on disk.** Leftovers from different AGP
versions sit side by side; the newest file wins and the freshness guard catches
the rest. Nothing here knows which AGP wrote which.

**The report can be older than the question.** Gradle skips the manifest task
when it considers it up to date. The tool compares the report against
`pubspec.lock`, `android/app/build.gradle` (or `.kts`) and the source-set
manifests the variant is built from — `report` warns, `check` and `baseline`
exit 64 — but it cannot catch a plugin whose own manifest changed inside the pub
cache at the same version.

**What the tool lists is not what Google Play sees.** Play derives *required
hardware features* from permissions at upload time, and the merger has no part
in it: `CAMERA` becomes a required `android.hardware.camera` and
`android.hardware.camera.autofocus`, `RECORD_AUDIO` becomes
`android.hardware.microphone`. Those requirements filter the app out of the
listing for devices without the hardware — a distribution failure with no error
message anywhere. This tool reports the permission and says nothing about the
feature.

## The one piece of good news

Every node of the merged manifest is either in the report or counted as
`unattributed`, in the output and in the baseline both. There is no category the
tool looks at and cannot see into, and no gap is ever presented as an absence.

## Not covered

- **Whether a permission is actually needed.** The tool says who declared it,
  never whether the code paths behind it run.
- **The Data Safety declaration itself.** It lives in the Play Console, and the
  contradiction that gets an app rejected is between two things only one of
  which is on disk.
- **iOS.** `Info.plist` purpose strings are not merged from pods at all, and
  ITMS-90683 happens because an SDK references an API in its binary. Different
  engine, different inputs, different accuracy — a separate package if it is
  ever worth building.
- **Manifest merge errors.** A conflict that fails the merge fails the Gradle
  build, before any report exists. That is the build's job.
- **Runtime permission requests, and components registered in code.** Neither is
  in any manifest.
- **`<permission>` declarations, dynamic feature modules, and other Gradle
  modules of a monorepo.** One application module per run, and only the
  `<uses-permission>` and `<uses-permission-sdk-23>` entries and the five
  component elements of its merged manifest.
- **What the packaging step does after the merge.** `packaged_manifests` differs
  from `merged_manifest` in placeholder substitution and version fields; the
  tool names which file it read and does not model the difference.
- **Historical drift.** The baseline is a snapshot, not a log. Git holds the
  history, and that is the right place for it.
