# Example

A Flutter app with a camera, Firebase messaging and a media picker, after
`flutter build apk`.

## What the merged manifest holds, and who put it there

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

Four permissions nobody in this project wrote. `RECORD_AUDIO` says `via camera`
because `camera_android_camerax` is a federated implementation — the pubspec
says `camera`, and that is the line to argue with. `WAKE_LOCK` names a Maven
artifact rather than a plugin: the report does not say which package pulled
the artifact in, and `./gradlew :app:dependencies` in `android/` does.
`INTERNET` appears twice because Flutter's own debug manifest declares it for
hot reload; it is not in the release variant.

## Where one of them comes from

```console
$ dart run appcraft_manifest_audit explain RECORD_AUDIO

android.permission.RECORD_AUDIO — debug

  camera_android_camerax 0.6.19                        via camera
    android/src/main/AndroidManifest.xml:10

  Not declared in android/app/src. To drop it:
    <uses-permission android:name="android.permission.RECORD_AUDIO"
        tools:node="remove" />
  as a direct child of <manifest> in android/app/src/main/AndroidManifest.xml.
```

"As a direct child of `<manifest>`" is in the output because getting it wrong is
a real and silent failure: nested inside an `<activity>`, the same three lines
do nothing at all and nothing warns you.

## Freezing the answer

```console
$ dart run appcraft_manifest_audit baseline
Wrote android/manifest_audit.yaml for debug. Commit it — the reviewer of that
commit is the approval mechanism.
```

```yaml
# android/manifest_audit.yaml
version: 1
variants:
  debug:
    application-id: com.example.demo_app
    permissions:
      android.permission.ACCESS_ADSERVICES_AD_ID:
        - androidx.privacysandbox.ads:ads-adservices
      android.permission.INTERNET:
        - app/src/debug
        - app/src/main
      android.permission.RECORD_AUDIO:
        - camera_android_camerax
      android.permission.WAKE_LOCK:
        - com.google.firebase:firebase-messaging
    components:
      provider#androidx.startup.InitializationProvider:
        - androidx.startup:startup-runtime
        - firebase_core
```

## In CI

Add an analytics SDK, build, and the check fails:

```console
$ flutter build apk --release --flavor prod
$ dart run appcraft_manifest_audit check --variant prod-release
prod-release: 1 new entry.

  + com.google.android.gms.permission.AD_ID            appsflyer_sdk

Review them, then run "dart run appcraft_manifest_audit baseline" and commit
the change. A permission that contradicts the Data Safety declaration is what
gets a release rejected.
```

Exit code 1. `AD_ID` is the one that matters here: an SDK declares it for you,
the Data Safety form does not know about it, and the release is rejected.

Read it, then accept it:

```console
$ dart run appcraft_manifest_audit baseline --variant prod-release
```

The diff in that commit is the record of the decision, and its reviewer is the
approval.

## Narrowing it to the variant you ship

```yaml
appcraft_manifest_audit:
  variants:
    - prod-release
```

Without this, `check` audits every variant with a report on disk — including
`debug`, whose `INTERNET` and dev-dependency plugins never reach Google Play.
