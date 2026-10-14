import 'package:appcraft_manifest_audit/appcraft_manifest_audit.dart';
import 'package:test/test.dart';

const String _manifest = '''
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.demoshop" >

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.CAMERA" />

    <queries>
        <package android:name="ru.bank.alpha" />
    </queries>

    <application android:label="demo" >
        <activity android:name="com.demoshop.MainActivity" />
        <service android:name="com.demoshop.Sync" />
        <receiver android:name="com.demoshop.Boot" />
        <provider android:name="androidx.startup.InitializationProvider" />
        <meta-data android:name="com.demoshop.key" android:value="x" />
    </application>

</manifest>
''';

void main() {
  test('reads the permissions of the merged manifest', () {
    expect(
      readMergedManifest(_manifest).permissions,
      <String>{
        'android.permission.INTERNET',
        'android.permission.CAMERA',
      },
    );
  });

  test('keys a <uses-permission-sdk-23> apart from a <uses-permission>', () {
    expect(
      readMergedManifest('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission-sdk-23 android:name="android.permission.CAMERA" />
</manifest>
''').permissions,
      <String>{
        'android.permission.CAMERA',
        'uses-permission-sdk-23#android.permission.CAMERA',
      },
    );
  });

  test('reads the components and leaves meta-data and queries out', () {
    expect(
      readMergedManifest(_manifest).components,
      <String>{
        'activity#com.demoshop.MainActivity',
        'service#com.demoshop.Sync',
        'receiver#com.demoshop.Boot',
        'provider#androidx.startup.InitializationProvider',
      },
    );
  });

  test('reads the application id off the package attribute', () {
    expect(readMergedManifest(_manifest).applicationId, 'com.demoshop');
  });

  test('ignores a uses-permission nested where Android does not read it', () {
    final nodes = readMergedManifest('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
        <activity android:name="com.demoshop.MainActivity">
            <uses-permission android:name="com.google.android.gms.permission.AD_ID" />
        </activity>
    </application>
</manifest>
''');

    expect(nodes.permissions, isEmpty);
  });

  test('reads the blame file the same way as the manifest it annotates', () {
    final nodes = readBlameFile(r'''
1<?xml version="1.0" encoding="utf-8"?>
2<manifest xmlns:android="http://schemas.android.com/apk/res/android"
3    package="com.demosite" >
3-->C:\Projects\demo_site\android\app\src\main\AndroidManifest.xml:1:1-38:12
4
5    <uses-permission android:name="android.permission.INTERNET" />
5-->C:\Projects\demo_site\android\app\src\main\AndroidManifest.xml:4:5-67
6
7    <application>
8        <provider android:name="androidx.startup.InitializationProvider" />
8-->[:firebase_core] C:\Projects\demo_site\build\firebase_core\AndroidManifest.xml:9:9-12:41
9    </application>
10</manifest>
''');

    expect(nodes.permissions, <String>{'android.permission.INTERNET'});
    expect(
      nodes.components,
      <String>{'provider#androidx.startup.InitializationProvider'},
    );
    expect(nodes.applicationId, 'com.demosite');
  });
}
