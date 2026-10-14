import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// The syntax of a merger report is documented nowhere. Every shape below is a
/// real one, taken from build output rather than from a specification, which is
/// why it is pinned here line by line.
void main() {
  test('reads the six verbs and no others', () {
    final report = parseMergerReport('''
-- Merging decision tree log ---
uses-permission#android.permission.CAMERA
ADDED from /app/src/main/AndroidManifest.xml:4:5-67
INJECTED from /app/src/debug/AndroidManifest.xml
MERGED from [:camera] /build/camera/AndroidManifest.xml:7:5-33:19
REJECTED from [com.example:legacy:1.0.0] /cache/legacy/AndroidManifest.xml:9:5-70
IMPLIED from /app/src/main/AndroidManifest.xml reason: com.example.old has a targetSdkVersion < 4
CONVERTED from /app/src/main/res/navigation/nav_graph.xml
''');

    expect(report.unparsed, isEmpty);
    expect(
      report.nodes.single.provenance.map((line) => line.verb),
      MergeVerb.values,
    );
  });

  test('leaves an unknown verb in unparsed rather than waving it through', () {
    final report = parseMergerReport('''
uses-permission#android.permission.CAMERA
ADOPTED from /app/src/main/AndroidManifest.xml:4:5-67
''');

    expect(report.nodes.single.provenance, isEmpty);
    expect(report.unparsed, hasLength(1));
  });

  test('leaves a line that parses as nothing in unparsed without throwing', () {
    final report = parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from /app/src/main/AndroidManifest.xml:4:5-67
what is this line even
''');

    expect(report.nodes.single.provenance, hasLength(1));
    expect(report.unparsed, <String>['what is this line even']);
  });

  test('reads the three owner shapes', () {
    final report = parseMergerReport(r'''
uses-permission#android.permission.CAMERA
ADDED from C:\Projects\demo\android\app\src\main\AndroidManifest.xml:4:5-67
MERGED from [:camera_android_camerax] C:\Projects\demo\build\camera_android_camerax\AndroidManifest.xml:7:5-33:19
MERGED from [androidx.camera:camera-camera2:1.4.1] C:\Users\dev\.gradle\caches\8.14.2\transforms\1b82\transformed\jetified-camera-camera2-1.4.1\AndroidManifest.xml:23:5-34:19
''');

    expect(
      report.nodes.single.provenance.map((line) => line.owner),
      <Owner>[
        const SourceSetOwner('app/src/main'),
        const SubprojectOwner('camera_android_camerax'),
        const MavenOwner(
          group: 'androidx.camera',
          artifact: 'camera-camera2',
          version: '1.4.1',
        ),
      ],
    );
  });

  test('reads an artifact with no group and no version, not a subproject', () {
    final report = parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from [:sdk:] /cache/sdk/AndroidManifest.xml:4:5-67
''');

    final owner = report.nodes.single.provenance.single.owner;
    expect(owner, const MavenOwner(group: '', artifact: 'sdk'));
    expect((owner as MavenOwner).module, 'sdk');
  });

  test('survives the colon of a Windows drive letter', () {
    final report = parseMergerReport(
      r'uses-permission#android.permission.CAMERA'
      '\n'
      r'ADDED from C:\Projects\demo\android\app\src\main\AndroidManifest.xml',
    );

    final line = report.nodes.single.provenance.single;
    expect(line.path,
        r'C:\Projects\demo\android\app\src\main\AndroidManifest.xml');
    expect(line.position, isNull);
  });

  test('reads a POSIX path', () {
    final report = parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from /home/dev/demo/android/app/src/main/AndroidManifest.xml:4:5-67
''');

    final line = report.nodes.single.provenance.single;
    expect(
        line.path, '/home/dev/demo/android/app/src/main/AndroidManifest.xml');
    expect(line.owner, const SourceSetOwner('app/src/main'));
  });

  test('reads the four position shapes', () {
    final report = parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from /a/AndroidManifest.xml:14:5-87:19
MERGED from /b/AndroidManifest.xml:11:5-47
MERGED from /c/AndroidManifest.xml:22:5
INJECTED from /d/AndroidManifest.xml
''');

    expect(
      report.nodes.single.provenance.map((line) => line.position?.toString()),
      <String?>['14:5-87:19', '11:5-47', '22:5', null],
    );
  });

  test('keeps a trailing reason out of the path', () {
    final report = parseMergerReport(r'''
uses-sdk
INJECTED from C:\Projects\demo\android\app\src\main\AndroidManifest.xml reason: use-sdk injection requested
''');

    final line = report.nodes.single.provenance.single;
    expect(line.path,
        r'C:\Projects\demo\android\app\src\main\AndroidManifest.xml');
    expect(line.reason, 'use-sdk injection requested');
  });

  test('reads a one-tab attribute name and its two-tab provenance', () {
    final report = parseMergerReport('''
uses-permission#android.permission.READ_EXTERNAL_STORAGE
ADDED from /app/src/main/AndroidManifest.xml:5:5-7:38
\tandroid:maxSdkVersion
\t\tADDED from [:photo_manager] /build/photo_manager/AndroidManifest.xml:11:9-35
''');

    final attribute = report.nodes.single.attributes.single;
    expect(attribute.name, 'android:maxSdkVersion');
    expect(attribute.provenance.single.owner,
        const SubprojectOwner('photo_manager'));
  });

  test('deduplicates a provenance line repeated verbatim', () {
    final report = parseMergerReport('''
uses-permission#android.permission.RECORD_AUDIO
MERGED from [:camera] /build/camera/AndroidManifest.xml:7:5-33:19
MERGED from [:camera] /build/camera/AndroidManifest.xml:7:5-33:19
MERGED from [:camera] /build/camera/AndroidManifest.xml:7:5-33:19
''');

    expect(report.nodes.single.provenance, hasLength(1));
  });

  test('splits a node key on the first hash only', () {
    final report = parseMergerReport('''
intent#action:name:android.intent.action.GET_CONTENT+data:mimeType:*/*
ADDED from /build/file_picker/AndroidManifest.xml:14:13-17:29
''');

    final node = report.nodes.single;
    expect(node.element, 'intent');
    expect(
      node.key,
      'action:name:android.intent.action.GET_CONTENT+data:mimeType:*/*',
    );
  });

  test('keeps a placeholder key and its substituted twin apart', () {
    final report = parseMergerReport(r'''
uses-permission#${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
ADDED from [androidx.core:core:1.15.0] /cache/core/AndroidManifest.xml:22:5-24:47
uses-permission#com.demoshop.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
ADDED from [androidx.core:core:1.15.0] /cache/core/AndroidManifest.xml:22:5-24:47
''');

    expect(
      report.nodes.map((node) => node.key),
      <String>[
        r'${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
        'com.demoshop.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
      ],
    );
  });

  test('strips the android: element prefix of old AGP', () {
    final report = parseMergerReport('''
android:uses-permission#android.permission.WRITE_EXTERNAL_STORAGE
IMPLIED from /app/src/main/AndroidManifest.xml reason: com.example.old has a targetSdkVersion < 4
''');

    expect(report.nodes.single.element, 'uses-permission');
    expect(report.nodes.single.nodeKey,
        'uses-permission#android.permission.WRITE_EXTERNAL_STORAGE');
  });

  test('reads the four reason literals of an implied permission', () {
    final report = parseMergerReport('''
uses-permission#android.permission.WRITE_EXTERNAL_STORAGE
IMPLIED from /a/AndroidManifest.xml reason: com.example.old has a targetSdkVersion < 4
uses-permission#android.permission.READ_EXTERNAL_STORAGE
IMPLIED from /a/AndroidManifest.xml reason: com.example.old requested WRITE_EXTERNAL_STORAGE
uses-permission#android.permission.READ_CALL_LOG
IMPLIED from /a/AndroidManifest.xml reason: com.example.old has targetSdkVersion < 16 and requested READ_CONTACTS
uses-permission#android.permission.WRITE_CALL_LOG
IMPLIED from /a/AndroidManifest.xml reason: com.example.old has targetSdkVersion < 16 and requested WRITE_CONTACTS
''');

    expect(report.unparsed, isEmpty);
    expect(
      report.nodes.map((node) => node.provenance.single.reason),
      <String>[
        'com.example.old has a targetSdkVersion < 4',
        'com.example.old requested WRITE_EXTERNAL_STORAGE',
        'com.example.old has targetSdkVersion < 16 and requested READ_CONTACTS',
        'com.example.old has targetSdkVersion < 16 and requested WRITE_CONTACTS',
      ],
    );
  });

  test('keeps a rejected library out of the owners of a node', () {
    final report = parseMergerReport('''
provider#com.vk.id.captcha.init.SdkInitContentProvider
ADDED from [com.vk.id:network:2.6.0] /cache/network/AndroidManifest.xml:11:9-13:35
REJECTED from [com.vk.id.captcha:vkid-captcha:0.0.10] /cache/captcha/AndroidManifest.xml:15:9-18:40
''');

    final node = report.nodes.single;
    expect(node.acceptedProvenance, hasLength(1));
    expect(
      node.rejectedProvenance.single.owner,
      const MavenOwner(
        group: 'com.vk.id.captcha',
        artifact: 'vkid-captcha',
        version: '0.0.10',
      ),
    );
  });

  test('reads the hand-written fixture of an old AGP whole', () {
    final report = parseMergerReport(
      fixture('implied', 'manifest-merger-debug-report.txt'),
    );

    expect(report.unparsed, isEmpty);
    expect(
      <String>[
        for (final node in report.nodesOf('uses-permission')) node.key!,
      ],
      <String>[
        'android.permission.WRITE_EXTERNAL_STORAGE',
        'android.permission.READ_PHONE_STATE',
        'android.permission.READ_EXTERNAL_STORAGE',
        'android.permission.READ_CALL_LOG',
        'android.permission.WRITE_CALL_LOG',
      ],
    );
    expect(
      report.nodesOf('uses-permission').every(
            (node) => node.provenance.single.verb == MergeVerb.implied,
          ),
      isTrue,
    );
  });

  test('skips the header and the blank lines', () {
    final report = parseMergerReport('''
-- Merging decision tree log ---

uses-permission#android.permission.CAMERA

ADDED from /app/src/main/AndroidManifest.xml:4:5-67
''');

    expect(report.unparsed, isEmpty);
    expect(report.nodes, hasLength(1));
  });
}
