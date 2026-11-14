import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pcl_pw/core/updater.dart';

Release rel(String tag, {bool pre = false, String commit = 'main', List<String> files = const []}) => Release.fromJson({
  'tag_name': tag,
  'prerelease': pre,
  'target_commitish': commit,
  'assets': [
    for (final f in files) {'name': f, 'browser_download_url': 'https://example.invalid/$f', 'size': 1},
  ],
});

void main() {
  test('版本号比较', () {
    expect(compareVersions('0.3.1', '0.3.0'), greaterThan(0));
    expect(compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    expect(compareVersions('v0.3.0', '0.3.0'), 0);
    expect(compareVersions('0.4.0', '0.4.0-beta.2'), greaterThan(0));
    expect(compareVersions('0.4.0-beta.2', '0.4.0-beta.1'), greaterThan(0));
    expect(compareVersions('0.4.0-beta.10', '0.4.0-beta.9'), greaterThan(0));
    expect(compareVersions('0.4.0-rc.1', '0.4.0-beta.5'), greaterThan(0));
    expect(compareVersions('0.4.0-beta', '0.3.9'), greaterThan(0));
    expect(compareVersions('1.0', '1.0.0'), 0);
  });

  final list = [
    rel('nightly', pre: true, commit: 'abcdef1234567890'),
    rel('v0.4.0-beta.1', pre: true),
    rel('v0.3.0'),
    rel('v0.2.1'),
    rel('some-other-tag'),
  ];

  test('按通道选择最新的发布', () {
    expect(latestRelease(list, UpdateChannel.stable)?.tag, 'v0.3.0');
    expect(latestRelease(list, UpdateChannel.preview)?.tag, 'v0.4.0-beta.1');
    expect(latestRelease(list, UpdateChannel.nightly)?.tag, 'nightly');
    // 预览版通道里正式版更新时选正式版
    expect(latestRelease([...list, rel('v0.4.0')], UpdateChannel.preview)?.tag, 'v0.4.0');
    expect(latestRelease([rel('nightly', pre: true)], UpdateChannel.stable), isNull);
  });

  test('是否需要更新', () {
    expect(isNewer(rel('v0.3.0'), currentVersion: '0.3.0'), isFalse);
    expect(isNewer(rel('v0.3.1'), currentVersion: '0.3.0'), isTrue);
    expect(isNewer(rel('v0.4.0-beta.1', pre: true), currentVersion: '0.4.0'), isFalse);
    final nightly = rel('nightly', pre: true, commit: 'abcdef1234567890');
    expect(isNewer(nightly, currentCommit: 'abcdef1234567890'), isFalse);
    expect(isNewer(nightly, currentCommit: 'abcdef1'), isFalse);
    expect(isNewer(nightly, currentCommit: '1234567'), isTrue);
    // 本地构建没有提交号
    expect(isNewer(nightly, currentCommit: ''), isTrue);
  });

  test('Windows 按程序架构选择安装包', () {
    final r = rel(
      'nightly',
      files: [
        'PixelWorld-nightly-abc1234-windows-x64-setup.exe',
        'PixelWorld-nightly-abc1234-windows-x64-portable.zip',
        'PixelWorld-nightly-abc1234-windows-arm64-setup.exe',
        'PixelWorld-nightly-abc1234-windows-arm64-portable.zip',
      ],
    );
    String? pick(String arch, bool installed) =>
        assetFor(r, android: false, windows: true, installed: installed, arch: arch)?.name;
    expect(pick('x64', true), 'PixelWorld-nightly-abc1234-windows-x64-setup.exe');
    expect(pick('x64', false), 'PixelWorld-nightly-abc1234-windows-x64-portable.zip');
    expect(pick('arm64', true), 'PixelWorld-nightly-abc1234-windows-arm64-setup.exe');
    expect(pick('arm64', false), 'PixelWorld-nightly-abc1234-windows-arm64-portable.zip');
    // 没有 arm64 包的旧发布：ARM64 版找不到对应的包，不会误装 x64 版
    final old = rel('v0.3.3', files: ['PCL.PW-0.3.3-windows-x64-setup.exe']);
    expect(assetFor(old, android: false, windows: true, installed: true, arch: 'arm64'), isNull);
  });

  test('按平台选择发布文件', () {
    final r = rel(
      'v0.3.0',
      files: [
        'PCL.PW-0.3.0-android-arm64.apk',
        'PCL.PW-0.3.0-windows-x64-portable.zip',
        'PCL.PW-0.3.0-windows-x64-setup.exe',
      ],
    );
    expect(assetFor(r, android: true, windows: false)?.name, endsWith('.apk'));
    expect(assetFor(r, android: false, windows: true, installed: true)?.name, endsWith('-setup.exe'));
    expect(assetFor(r, android: false, windows: true, installed: false)?.name, endsWith('-portable.zip'));
    expect(assetFor(r, android: false, windows: false, macos: false), isNull);
    final n = rel('nightly', files: ['PCL.PW-nightly-abc1234-android-arm64.apk']);
    expect(assetFor(n, android: true, windows: false)?.name, 'PCL.PW-nightly-abc1234-android-arm64.apk');
  });

  test('发布文件改名为 PixelWorld- 后仍按后缀选中（旧版本的更新器也只看后缀）', () {
    final r = rel(
      'nightly',
      files: [
        'PixelWorld-nightly-abc1234-android-arm64.apk',
        'PixelWorld-nightly-abc1234-linux-x64.tar.gz',
        'PixelWorld-nightly-abc1234-macos.dmg',
        'PixelWorld-nightly-abc1234-windows-x64-portable.zip',
        'PixelWorld-nightly-abc1234-windows-x64-setup.exe',
      ],
    );
    expect(assetFor(r, android: true, windows: false)?.name, 'PixelWorld-nightly-abc1234-android-arm64.apk');
    expect(assetFor(r, android: false, windows: true, installed: true)?.name, endsWith('-windows-x64-setup.exe'));
    expect(assetFor(r, android: false, windows: true, installed: false)?.name, endsWith('-windows-x64-portable.zip'));
    expect(assetFor(r, android: false, windows: false, macos: true)?.name, endsWith('-macos.dmg'));
  });

  test('便携版更新认得新旧两个主程序名，换名时删掉旧名字的程序', () {
    final dir = Directory.systemTemp.createTempSync('pw-portable');
    try {
      final src = p.join(dir.path, 'src');
      final dst = p.join(dir.path, 'dst');
      Directory(src).createSync();
      expect(() => portableUpdateScript(source: src, target: dst, pid: 1), throwsException);

      File(p.join(src, 'PCL.PW.exe')).writeAsStringSync('');
      var s = portableUpdateScript(source: src, target: dst, pid: 1);
      expect(s.last, "Start-Process '${p.join(dst, 'PCL.PW.exe')}'");
      expect(s.where((c) => c.startsWith('Remove-Item')).single, contains("'${p.join(dst, 'Pixel World.exe')}'"));

      File(p.join(src, 'PCL.PW.exe')).deleteSync();
      File(p.join(src, 'Pixel World.exe')).writeAsStringSync('');
      s = portableUpdateScript(source: src, target: dst, pid: 1);
      expect(s.last, "Start-Process '${p.join(dst, 'Pixel World.exe')}'");
      expect(s.where((c) => c.startsWith('Remove-Item')).single, contains("'${p.join(dst, 'PCL.PW.exe')}'"));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('读取 GitHub 提供的 SHA-256', () {
    final r = Release.fromJson({
      'tag_name': 'v1.0.0',
      'assets': [
        {'name': 'a.apk', 'browser_download_url': 'u', 'size': 3, 'digest': 'sha256:${'a' * 64}'},
        {'name': 'b.apk', 'browser_download_url': 'u', 'size': 3, 'digest': null},
      ],
    });
    expect(r.assets[0].sha256, 'a' * 64);
    expect(r.assets[1].sha256, isNull);
  });

  test('已下载的更新文件核对通过后直接复用，不再联网', () async {
    final dir = Directory.systemTemp.createTempSync('pclpw-update-reuse');
    try {
      final bytes = utf8.encode('already downloaded');
      final file = File(p.join(dir.path, 'reuse.bin'))..writeAsBytesSync(bytes);
      final asset = ReleaseAsset(
        name: 'reuse.bin',
        url: 'https://example.invalid/never',
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
      var progress = -1;
      final out = await downloadAsset(asset, directory: dir, onProgress: (done, total) => progress = done);
      expect(out.path, file.path);
      expect(progress, bytes.length);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
