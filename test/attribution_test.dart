import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Attribution _debug({bool withManifest = true}) => attribute(
      variant: 'debug',
      report: parseMergerReport(
        fixture('debug', 'manifest-merger-debug-report.txt'),
      ),
      nodes: withManifest
          ? readMergedManifest(fixture('debug', 'AndroidManifest.xml'))
          : null,
      plugins: PluginIndex.parse(pluginsJson, declared: declared),
      pluginReports: pluginReports,
    );

List<String> _ownersOf(Attribution attribution, String key) =>
    attribution.permissions
        .followedBy(attribution.components)
        .followedBy(attribution.suppressed)
        .firstWhere((entry) => entry.key == key)
        .labels;

void main() {
  group('tier 1 — the subproject name is the pub package name', () {
    test('names the plugin behind a permission', () {
      expect(
        _ownersOf(_debug(), 'android.permission.RECORD_AUDIO'),
        <String>['camera_android_camerax (via camera)'],
      );
    });

    test('names the package the pubspec declares, not the implementation', () {
      final owner = _debug()
          .permissions
          .firstWhere((entry) => entry.key == 'android.permission.RECORD_AUDIO')
          .owners
          .first
          .owner as PluginOwner;

      expect(owner.package, 'camera_android_camerax');
      expect(owner.via, <String>['camera']);
      expect(owner.version, '0.6.19');
    });

    test('leaves a declared package without a via', () {
      final owner = _debug()
          .components
          .firstWhere((entry) =>
              entry.key ==
              'service#io.flutter.plugins.firebase.messaging.'
                  'FlutterFirebaseMessagingService')
          .owners
          .first
          .owner as PluginOwner;

      expect(owner.package, 'firebase_messaging');
      expect(owner.via, isEmpty);
    });

    test('marks a dev-dependency plugin, whose permission is debug-only', () {
      final owner = _debug()
          .permissions
          .firstWhere((entry) => entry.key == 'android.permission.VIBRATE')
          .owners
          .single
          .owner as PluginOwner;

      expect(owner.package, 'vibration');
      expect(owner.devDependency, isTrue);
    });
  });

  group('a Maven artifact is named as itself', () {
    test('names the artifact, with the plugin reports on disk', () {
      expect(
        _ownersOf(_debug(), 'android.permission.WAKE_LOCK'),
        <String>['com.google.firebase:firebase-messaging'],
      );
    });

    test('keeps the version for explain', () {
      final owner = _debug()
          .permissions
          .firstWhere((entry) => entry.key == 'android.permission.WAKE_LOCK')
          .owners
          .first
          .owner as ArtifactOwner;

      expect(
        owner.artifact.toString(),
        'com.google.firebase:firebase-messaging:24.1.0',
      );
    });

    test('records group:artifact in the baseline', () {
      final entry = _debug().permissions.firstWhere(
            (entry) =>
                entry.key == 'android.permission.ACCESS_ADSERVICES_AD_ID',
          );

      expect(
        entry.baselineOwners.single.key,
        'androidx.privacysandbox.ads:ads-adservices',
      );
      expect(entry.baselineOwners.single.note, isNull);
    });

    test('lists a plugin and an artifact that both merged an entry', () {
      expect(
        _ownersOf(_debug(), 'provider#androidx.startup.InitializationProvider'),
        <String>['androidx.startup:startup-runtime', 'firebase_core'],
      );
    });

    test('names an artifact with no group, never a local Gradle module', () {
      final attribution = attribute(
        variant: 'debug',
        report: parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from [:sdk:] /cache/sdk/AndroidManifest.xml:4:5-67
'''),
        nodes: null,
      );

      expect(attribution.permissions.single.labels, <String>['sdk']);
    });
  });

  group('a subproject with no pub entry', () {
    test('labels a subproject with no pub entry as a local Gradle module', () {
      final attribution = attribute(
        variant: 'debug',
        report: parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from [:shared_native] /build/shared_native/AndroidManifest.xml:4:5-67
'''),
        nodes: null,
      );

      expect(
        attribution.permissions.single.labels,
        <String>['shared_native (local Gradle module)'],
      );
      expect(attribution.permissions.single.baselineOwners.single.key,
          ':shared_native');
    });
  });

  group('the app', () {
    test('names the source set of a permission the app declares', () {
      expect(
        _ownersOf(_debug(), 'android.permission.INTERNET'),
        <String>['app/src/debug', 'app/src/main'],
      );
    });

    test('separates what the app declares from what libraries inject', () {
      final attribution = _debug();

      expect(
        <String>[
          for (final entry in attribution.permissions)
            if (entry.declaredByApp) entry.key,
        ],
        <String>[
          'android.permission.INTERNET',
          'android.permission.READ_EXTERNAL_STORAGE',
        ],
      );
    });

    test('keeps an attribute owner out of the owners of its node', () {
      final entry = _debug().permissions.firstWhere(
            (entry) => entry.key == 'android.permission.READ_EXTERNAL_STORAGE',
          );

      expect(entry.labels, <String>['app/src/main']);
      expect(
        entry.attributes
            .firstWhere(
                (attribute) => attribute.name == 'android:maxSdkVersion')
            .owners
            .single
            .owner
            .label,
        'photo_manager',
      );
    });
  });

  test('reports a manifest permission with no node in the report', () {
    expect(
      _debug().unattributed,
      <String>['android.permission.POST_NOTIFICATIONS'],
    );
  });

  test('leaves an ignored name out of every list', () {
    final attribution = attribute(
      variant: 'debug',
      report: parseMergerReport(
        fixture('debug', 'manifest-merger-debug-report.txt'),
      ),
      nodes: readMergedManifest(fixture('debug', 'AndroidManifest.xml')),
      ignore: const <String>[
        'android.permission.INTERNET',
        'android.permission.POST_NOTIFICATIONS',
      ],
    );

    expect(
      attribution.permissions.map((entry) => entry.key),
      isNot(contains('android.permission.INTERNET')),
    );
    expect(attribution.unattributed, isEmpty);
  });

  test('matches an ignore entry on the whole name, never on a prefix', () {
    final attribution = attribute(
      variant: 'debug',
      report: parseMergerReport(
        fixture('debug', 'manifest-merger-debug-report.txt'),
      ),
      nodes: readMergedManifest(fixture('debug', 'AndroidManifest.xml')),
      ignore: const <String>['android.permission.READ_'],
    );

    expect(
      attribution.permissions.map((entry) => entry.key),
      contains('android.permission.READ_EXTERNAL_STORAGE'),
    );
  });

  test('keeps a <uses-permission-sdk-23> apart from a <uses-permission>', () {
    final attribution = attribute(
      variant: 'release',
      report: parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from /app/src/main/AndroidManifest.xml:4:5-67
uses-permission-sdk-23#android.permission.CAMERA
ADDED from [:camera_x] /build/camera_x/AndroidManifest.xml:7:5-79
'''),
      nodes: readMergedManifest('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission-sdk-23 android:name="android.permission.CAMERA" />
</manifest>
'''),
    );

    expect(
      attribution.permissions.map((entry) => entry.key),
      <String>['uses-permission-sdk-23#android.permission.CAMERA'],
    );
    expect(
      attribution.suppressed.map((entry) => entry.key),
      <String>['android.permission.CAMERA'],
    );
    expect(attribution.unattributed, isEmpty);
  });

  group('the report is not the answer — the merged manifest is', () {
    test('reports a removed permission as suppressed, never as present', () {
      final attribution =
          recordedAttribution('removed', 'release', 'AndroidManifest.xml');

      expect(
        attribution.suppressed.map((entry) => entry.key),
        <String>[
          'android.permission.READ_MEDIA_IMAGES',
          'android.permission.READ_MEDIA_VIDEO',
          'android.permission.WRITE_EXTERNAL_STORAGE',
        ],
      );
      expect(
        attribution.permissions.map((entry) => entry.key),
        <String>['android.permission.INTERNET'],
      );
    });

    test('agrees with itself when the blame file stands in', () {
      final attribution = attribute(
        variant: 'release',
        report: parseMergerReport(
          fixture('removed', 'manifest-merger-release-report.txt'),
        ),
        nodes: readBlameFile(
          fixture('removed', 'manifest-merger-blame-release-report.txt'),
        ),
      );

      expect(attribution.suppressed, hasLength(3));
      expect(
        attribution.permissions.map((entry) => entry.key),
        <String>['android.permission.INTERNET'],
      );
    });

    test('says so when it has neither, instead of guessing', () {
      final attribution = _debug(withManifest: false);

      expect(attribution.degraded, isTrue);
      expect(attribution.suppressed, isEmpty);
      expect(
        attribution.permissions.map((entry) => entry.key),
        contains('android.permission.WAKE_LOCK'),
      );
    });
  });

  group('flavours and the application id', () {
    test('folds a substituted permission onto its placeholder', () {
      final attribution = prodRelease();

      expect(attribution.applicationId, 'com.demoshop');
      expect(
        attribution.permissions.map((entry) => entry.key),
        <String>[
          r'${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
          'android.permission.INTERNET',
          'com.google.android.gms.permission.AD_ID',
        ],
      );
    });

    test('gives two flavours the same key for the same node', () {
      final beta = recordedAttribution(
          'release', 'beta-release', 'AndroidManifest-beta.xml');

      expect(beta.applicationId, 'com.demoshop.beta');
      expect(
        beta.permissions.map((entry) => entry.key),
        contains(r'${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'),
      );
    });

    test('folds a placeholder-named component the manifest holds', () {
      final attribution = attribute(
        variant: 'release',
        report: parseMergerReport(r'''
receiver#${applicationId}.PushReceiver
ADDED from [:push] /build/push/AndroidManifest.xml:9:9-12:20
receiver#com.demoshop.PushReceiver
MERGED from [:push] /build/push/AndroidManifest.xml:9:9-12:20
'''),
        nodes: readMergedManifest('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.demoshop">
    <application>
        <receiver android:name="com.demoshop.PushReceiver" />
    </application>
</manifest>
'''),
      );

      expect(
        attribution.components.map((entry) => entry.key),
        <String>[r'receiver#${applicationId}.PushReceiver'],
      );
      expect(attribution.suppressed, isEmpty);
      expect(attribution.unattributed, isEmpty);
    });

    test('reads the application id off the report when no manifest is there',
        () {
      final attribution = attribute(
        variant: 'prod-release',
        report: parseMergerReport(
          fixture('release', 'manifest-merger-prod-release-report.txt'),
        ),
        nodes: null,
      );

      expect(attribution.applicationId, 'com.demoshop');
    });
  });

  test('lists every library that merged an entry, once each', () {
    expect(
      prodRelease()
          .permissions
          .firstWhere(
            (entry) => entry.key == 'com.google.android.gms.permission.AD_ID',
          )
          .baselineOwners
          .map((owner) => owner.key),
      <String>[
        'com.appsflyer:af-android-sdk',
        'com.google.android.gms:play-services-ads-identifier',
        'com.google.android.gms:play-services-measurement-api',
        'io.appmetrica.analytics:analytics-identifiers',
      ],
    );
  });

  test('keeps a rejected declaration out of report and in explain', () {
    final entry = prodRelease().components.firstWhere(
          (entry) =>
              entry.key ==
              'provider#com.vk.id.captcha.init.SdkInitContentProvider',
        );

    expect(entry.labels, <String>['com.vk.id:network']);
    expect(entry.rejected, hasLength(1));
    expect(
      (entry.rejected.single.owner as ArtifactOwner).artifact.toString(),
      'com.vk.id.captcha:vkid-captcha:0.0.10',
    );
  });

  test('summarises the queries block instead of listing it', () {
    final queries = prodRelease().queries;

    expect(queries.packages, 5);
    expect(queries.owners, <String>['app/src/main', 'com.demopay:sdk']);
  });

  test('attributes an implied permission to the report that granted it', () {
    final attribution = attribute(
      variant: 'debug',
      report: parseMergerReport(
        fixture('implied', 'manifest-merger-debug-report.txt'),
      ),
      nodes: readMergedManifest(fixture('implied', 'AndroidManifest.xml')),
    );

    expect(attribution.permissions, hasLength(5));
    expect(
      _ownersOf(attribution, 'android.permission.WRITE_EXTERNAL_STORAGE'),
      <String>['app/src/main'],
    );
    expect(attribution.unattributed, isEmpty);
  });

  test('counts the lines it could not parse', () {
    final attribution = attribute(
      variant: 'debug',
      report: parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from /app/src/main/AndroidManifest.xml:4:5-67
ADOPTED from /app/src/main/AndroidManifest.xml:4:5-67
'''),
      nodes: null,
    );

    expect(attribution.unparsed, 1);
  });
}
