import 'package:xml/xml.dart';

/// What the app actually has, read from a merged manifest.
///
/// The report is a log of decisions considered, not of results: a node removed
/// with `tools:node="remove"` is recorded as `ADDED` there and is absent here.
/// So the merged manifest is the authority for what the app has, and the report
/// is the authority for who wanted it.
final class ManifestNodes {
  /// Creates a set of nodes.
  const ManifestNodes({
    required this.permissions,
    required this.components,
    this.applicationId,
  });

  /// Permissions, keyed as [permissionKey] spells them.
  final Set<String> permissions;

  /// Components, keyed `<element>#<android:name>`.
  ///
  /// Only the four manifest-declared component types and `activity-alias` are
  /// read; a `meta-data` or a `<package>` of `<queries>` is not a component.
  final Set<String> components;

  /// Value of the `package` attribute, absent when the manifest carries none.
  ///
  /// The merger substitutes it into `${applicationId}` placeholders, so the
  /// same node has a different name per flavour.
  final String? applicationId;

  /// Elements read as permissions.
  static const Set<String> permissionElements = <String>{
    'uses-permission',
    'uses-permission-sdk-23',
  };

  /// Elements read as components.
  static const Set<String> componentElements = <String>{
    'activity',
    'activity-alias',
    'service',
    'receiver',
    'provider',
  };

  /// Key of the permission [name] declared by [element].
  ///
  /// A `<uses-permission>` is keyed by its name and a
  /// `<uses-permission-sdk-23>` as `uses-permission-sdk-23#<name>`: the merger
  /// keeps the two apart, so the same name under both is two nodes, each
  /// removed on its own.
  static String permissionKey(String element, String name) =>
      element == 'uses-permission' ? name : '$element#$name';
}

/// Reads a merged `AndroidManifest.xml`.
///
/// Only the placements Android itself honours are read: a `<uses-permission>`
/// is a direct child of `<manifest>` and a component a direct child of
/// `<application>`. One nested anywhere else is ignored by the platform, so
/// counting it here would report a permission the app does not have.
///
/// Throws an [XmlException] when the content is not XML.
ManifestNodes readMergedManifest(String xml) {
  final document = XmlDocument.parse(xml);
  final root = document.rootElement;

  final permissions = <String>{
    for (final element in root.childElements)
      if (ManifestNodes.permissionElements.contains(element.localName))
        if (_androidName(element) case final String name)
          ManifestNodes.permissionKey(element.localName, name),
  };

  final components = <String>{};
  for (final application in root.childElements) {
    if (application.localName != 'application') continue;

    for (final element in application.childElements) {
      if (!ManifestNodes.componentElements.contains(element.localName)) {
        continue;
      }
      if (_androidName(element) case final String name) {
        components.add('${element.localName}#$name');
      }
    }
  }

  return ManifestNodes(
    permissions: permissions,
    components: components,
    applicationId: _attribute(root, 'package'),
  );
}

/// Value of `android:name`, tolerating a manifest that leaves the prefix out.
String? _androidName(XmlElement element) {
  for (final attribute in element.attributes) {
    if (attribute.name.local != 'name') continue;

    final prefix = attribute.name.prefix;
    if (prefix == null || prefix == 'android') return attribute.value;
  }

  return null;
}

String? _attribute(XmlElement element, String name) {
  for (final attribute in element.attributes) {
    if (attribute.name.qualified == name) return attribute.value;
  }

  return null;
}

/// Reads the merger's blame file, which is the merged manifest annotated with
/// the origin of every line.
///
/// It reflects the final manifest, so it answers the same question as
/// [readMergedManifest] and rescues a build whose merged manifest is not on
/// disk. It is not the primary source: it lists only the winning origin per
/// line, so neither "who else wanted this" nor the suppressed set can be
/// derived from it.
ManifestNodes readBlameFile(String content) => readMergedManifest(
      stripBlameAnnotations(content),
    );

/// Strips the line numbers and the `-->` origin lines of a blame file, leaving
/// the manifest itself.
String stripBlameAnnotations(String content) {
  final manifest = StringBuffer();

  for (final raw in content.split('\n')) {
    final line = raw.replaceAll('\r', '');
    if (_origin.hasMatch(line)) continue;

    final numbered = _numbered.firstMatch(line);
    manifest.writeln(numbered == null ? line : numbered.group(1));
  }

  return manifest.toString();
}

final RegExp _origin = RegExp(r'^\d+-->');
final RegExp _numbered = RegExp(r'^\d+(.*)$');
