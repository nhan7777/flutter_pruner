import 'dart:io';

import 'package:flutter_pruner/src/adapters/go_router/deep_link_probe.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> loadProject(
  Directory root, {
  List<BuildTarget>? targets,
}) async {
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: probe_app
publish_to: none
environment:
  sdk: ^3.9.0
''');
  return ProjectContext.load(root, targets: targets);
}

void main() {
  group('DeepLinkProbe', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('deep_link_probe'));
    tearDown(() => root.deleteSync(recursive: true));

    test('reports no evidence for a project without platform config', () async {
      final project = await loadProject(root);

      final evidence = DeepLinkProbe.detect(project);

      expect(evidence.enabled, isFalse);
      expect(evidence.sources, isEmpty);
    });

    test('detects an Android autoVerify intent filter', () async {
      final manifestPath = p.join(
        root.path,
        'android',
        'app',
        'src',
        'main',
        'AndroidManifest.xml',
      );
      Directory(p.dirname(manifestPath)).createSync(recursive: true);
      File(manifestPath).writeAsStringSync('''
<manifest>
  <application>
    <activity android:name=".MainActivity">
      <intent-filter android:autoVerify="true">
        <data android:scheme="https" android:host="example.com" />
      </intent-filter>
    </activity>
  </application>
</manifest>
''');
      final project = await loadProject(root);

      final evidence = DeepLinkProbe.detect(project);

      expect(evidence.enabled, isTrue);
      expect(evidence.sources, ['android/app/src/main/AndroidManifest.xml']);
    });

    test('detects an iOS associated-domains entitlement', () async {
      final entitlementPath = p.join(
        root.path,
        'ios',
        'Runner',
        'Runner.entitlements',
      );
      Directory(p.dirname(entitlementPath)).createSync(recursive: true);
      File(entitlementPath).writeAsStringSync('''
<plist version="1.0">
<dict>
  <key>com.apple.developer.associated-domains</key>
  <array><string>applinks:example.com</string></array>
</dict>
</plist>
''');
      final project = await loadProject(root);

      final evidence = DeepLinkProbe.detect(project);

      expect(evidence.enabled, isTrue);
      expect(evidence.sources, ['ios/Runner/Runner.entitlements']);
    });

    test('ignores an Android manifest without deep-link config', () async {
      final manifestPath = p.join(
        root.path,
        'android',
        'app',
        'src',
        'main',
        'AndroidManifest.xml',
      );
      Directory(p.dirname(manifestPath)).createSync(recursive: true);
      File(manifestPath).writeAsStringSync('''
<manifest>
  <application android:label="probe_app" />
</manifest>
''');
      final project = await loadProject(root);

      final evidence = DeepLinkProbe.detect(project);

      expect(evidence.enabled, isFalse);
    });

    test('treats a web target as externally addressable', () async {
      final project = await loadProject(
        root,
        targets: [
          BuildTarget(
            name: 'web-prod',
            platform: 'web',
            entrypoint: 'lib/main.dart',
          ),
        ],
      );

      final evidence = DeepLinkProbe.detect(project);

      expect(evidence.enabled, isTrue);
      expect(evidence.sources, ['target:web-prod:web']);
    });
  });
}
