import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

VariantAudit _audit(String variant, String directory, String manifest) =>
    VariantAudit(
      attribution: recordedAttribution(directory, variant, manifest),
      report: 'build/app/outputs/logs/manifest-merger-$variant-report.txt',
      staleInputs: const <String>[],
      manifestSource: 'build/app/intermediates/$manifest',
    );

VariantAudit _inline(String report, Set<String> permissions) => VariantAudit(
      attribution: attribute(
        variant: 'release',
        report: parseMergerReport(report),
        nodes: ManifestNodes(
          permissions: permissions,
          components: const <String>{},
        ),
      ),
      report: 'build/app/outputs/logs/manifest-merger-release-report.txt',
      staleInputs: const <String>[],
      manifestSource: 'build/app/intermediates/AndroidManifest.xml',
    );

void main() {
  test('lists what the merger dropped under its own heading', () {
    expect(
      renderReport(_audit('release', 'removed', 'AndroidManifest.xml')),
      contains('Suppressed by tools:node="remove" (3):\n'
          '  android.permission.READ_MEDIA_IMAGES                 removed by '
          'app/src/main; wanted by open_filex (local Gradle module)\n'),
    );
  });

  test('tells the app to replace its own line when a library declares it too',
      () {
    final explained = renderExplain(
      <VariantAudit>[
        _inline('''
uses-permission#android.permission.READ_MEDIA_IMAGES
ADDED from /app/src/main/AndroidManifest.xml:4:5-67
MERGED from [:file_picker] /build/file_picker/AndroidManifest.xml:7:5-79
''', <String>{'android.permission.READ_MEDIA_IMAGES'}),
      ],
      'READ_MEDIA_IMAGES',
    );

    expect(
      explained,
      endsWith('  Declared in android/app/src and by a library as well. To\n'
          '  drop it, replace your own line with:\n'
          '    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"\n'
          '        tools:node="remove" />\n'
          '  as a direct child of <manifest> in '
          'android/app/src/main/AndroidManifest.xml.\n\n'),
    );
  });

  test('removes a <uses-permission-sdk-23> under <manifest>', () {
    final explained = renderExplain(
      <VariantAudit>[
        _inline('''
uses-permission-sdk-23#android.permission.CAMERA
ADDED from [:camera_x] /build/camera_x/AndroidManifest.xml:7:5-79
''', <String>{'uses-permission-sdk-23#android.permission.CAMERA'}),
      ],
      'CAMERA',
    );

    expect(
      explained,
      contains(
          '    <uses-permission-sdk-23 android:name="android.permission.CAMERA"\n'
          '        tools:node="remove" />\n'
          '  as a direct child of <manifest> in '),
    );
  });

  test('marks a newly suppressed entry apart from a removed one', () {
    final audit = _audit('release', 'removed', 'AndroidManifest.xml');

    expect(
      renderBaselineDiff(Baseline.parse('''
version: 1
variants:
  release:
    permissions:
      android.permission.CAMERA:
        - app/src/main
      android.permission.INTERNET:
        - app/src/main
''').diff(audit.attribution)),
      allOf(
        contains('  - android.permission.CAMERA '),
        contains('  x android.permission.READ_MEDIA_IMAGES '),
      ),
    );
  });

  test('summarises the queries block with a pointer at explain', () {
    final audit = _audit('prod-release', 'release', 'AndroidManifest-prod.xml');

    expect(
      renderReport(audit),
      contains('queries: 5 <package> entries from 2 libraries — not listed, '
          'see "explain queries".\n'),
    );
    expect(
      renderExplain(<VariantAudit>[audit], 'queries'),
      'queries — prod-release\n'
      '\n'
      '  5 <package> entries, from:\n'
      '    app/src/main\n'
      '    com.demopay:sdk\n'
      '\n',
    );
  });

  test('names the library that lost, apart from the ones that won', () {
    final explained = renderExplain(
      <VariantAudit>[
        _audit('prod-release', 'release', 'AndroidManifest-prod.xml')
      ],
      'SdkInitContentProvider',
    );

    expect(
      explained,
      contains(
          '  Also declared it and lost to a higher-priority manifest (1):\n'
          '    com.vk.id.captcha:vkid-captcha:0.0.10\n'),
    );
  });

  test('says a suppressed entry is suppressed before naming who wanted it', () {
    expect(
      renderExplain(
        <VariantAudit>[_audit('release', 'removed', 'AndroidManifest.xml')],
        'READ_MEDIA_IMAGES',
      ),
      startsWith('android.permission.READ_MEDIA_IMAGES — release\n'
          '\n'
          '  Suppressed: the report records it and the merged manifest does '
          'not hold it.\n'),
    );
  });

  test('names the app line of a suppressed entry as the removal', () {
    final explained = renderExplain(
      <VariantAudit>[_audit('release', 'removed', 'AndroidManifest.xml')],
      'READ_MEDIA_IMAGES',
    );

    expect(
      explained,
      contains('  app/src/main                                         '
          'removed by the app with tools:node="remove"\n'),
    );
    expect(explained, isNot(contains('declared by the app')));
  });

  test('renders a check that fails and one that only warns', () {
    final baseline = Baseline.parse('''
version: 1
variants:
  release:
    permissions:
      android.permission.CAMERA:
        - app/src/main
''');

    final added = baseline.diff(attribute(
      variant: 'release',
      report: parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from /app/src/main/AndroidManifest.xml:4:5-67
uses-permission#android.permission.RECORD_AUDIO
ADDED from [:camera_x] /build/camera_x/AndroidManifest.xml:7:5-79
'''),
      nodes: const ManifestNodes(
        permissions: <String>{
          'android.permission.CAMERA',
          'android.permission.RECORD_AUDIO',
        },
        components: <String>{},
      ),
    ));

    expect(
      renderCheck(added, strict: false),
      'release: 1 new entry.\n'
      '\n'
      '  + android.permission.RECORD_AUDIO                    :camera_x\n'
      '\n'
      'Review them, then run "dart run appcraft_manifest_audit baseline" and '
      'commit the change. A permission that contradicts the Data Safety '
      'declaration is what gets a release rejected.\n',
    );

    final drifted = baseline.diff(attribute(
      variant: 'release',
      report: parseMergerReport('''
uses-permission#android.permission.CAMERA
ADDED from /app/src/main/AndroidManifest.xml:4:5-67
MERGED from [:camera_x] /build/camera_x/AndroidManifest.xml:7:5-79
'''),
      nodes: const ManifestNodes(
        permissions: <String>{'android.permission.CAMERA'},
        components: <String>{},
      ),
    ));

    expect(
      renderCheck(drifted, strict: false),
      endsWith('None of this fails the check by default. Run with --strict to '
          'make owner changes, removals, new suppressions and application id '
          'changes fail as well.\n'),
    );
  });

  test('says the baseline is up to date rather than printing nothing', () {
    final audit = _audit('release', 'removed', 'AndroidManifest.xml');
    final baseline = Baseline.of(<Attribution>[audit.attribution]);

    expect(
      renderBaselineDiff(baseline.diff(audit.attribution)),
      'release: the baseline is up to date.\n',
    );
  });
}
