// 打包 Windows 版：先编译 Flutter，再生成便携版 zip 与带加载动画的安装程序。
// 安装程序外壳用系统自带的 .NET Framework 编译器 csc 编译，Windows 10 及以上与 GitHub Actions 都自带。
//
//   dart run tool/build_installer.dart
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> run(String exe, List<String> args, {String? cwd}) async {
  final proc = await Process.start(
    exe,
    args,
    workingDirectory: cwd,
    mode: ProcessStartMode.inheritStdio,
    runInShell: true,
  );
  final code = await proc.exitCode;
  if (code != 0) throw Exception('$exe 退出代码 $code');
}

Future<void> copyTree(Directory from, Directory to) async {
  await to.create(recursive: true);
  for (final e in from.listSync(recursive: true)) {
    final target = p.join(to.path, p.relative(e.path, from: from.path));
    if (e is Directory) {
      await Directory(target).create(recursive: true);
    } else if (e is File) {
      await File(target).parent.create(recursive: true);
      await e.copy(target);
    }
  }
}

Future<void> main() async {
  if (!Platform.isWindows) {
    stderr.writeln('只能在 Windows 上打包');
    exit(1);
  }
  final root = p.normalize(p.join(p.dirname(Platform.script.toFilePath()), '..'));
  final version = RegExp(
    r'^version:\s*([\d.]+)',
    multiLine: true,
  ).firstMatch(File(p.join(root, 'pubspec.yaml')).readAsStringSync())!.group(1)!;
  final windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
  // ARM64 版 Windows 上 64 位编译器可能在 FrameworkArm64 下；编出的外壳是 AnyCPU，两种都能用
  final csc =
      [
        for (final dir in ['Framework64', 'FrameworkArm64'])
          p.join(windir, 'Microsoft.NET', dir, 'v4.0.30319', 'csc.exe'),
      ].firstWhere(
        (f) => File(f).existsSync(),
        orElse: () => p.join(windir, 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe'),
      );
  // 用系统自带的 bsdtar 压缩；Git Bash 里的 tar 不支持 zip
  final tar = p.join(windir, 'System32', 'tar.exe');

  // 当前 Flutter 版本裁剪图标字体时会漏掉部分图标
  // 更新功能用到的构建信息（CI 中设置，见 .github/workflows/release.yml）
  final defines = [
    for (final k in ['PCLPW_COMMIT', 'PCLPW_CHANNEL', 'PCLPW_MS_CLIENT_ID'])
      if ((Platform.environment[k] ?? '').isNotEmpty) '--dart-define=$k=${Platform.environment[k]}',
  ];
  await run('flutter', ['build', 'windows', '--release', '--no-tree-shake-icons', ...defines], cwd: root);

  // Flutter 按本机架构输出到 build/windows/x64 或 build/windows/arm64；也可以用 PW_ARCH 指定
  String release(String arch) => p.join(root, 'build', 'windows', arch, 'runner', 'Release');
  final arch =
      Platform.environment['PW_ARCH'] ??
      (Directory(release('arm64')).existsSync() && !Directory(release('x64')).existsSync() ? 'arm64' : 'x64');
  stdout.writeln('架构：$arch');
  final dist = Directory(p.join(root, 'dist'));
  final name = 'PixelWorld-$version-windows-$arch';
  final stage = Directory(p.join(dist.path, name));
  if (stage.existsSync()) await stage.delete(recursive: true);
  await copyTree(Directory(release(arch)), stage);
  // Flutter 的可执行文件名不能带点，发布时改名（和 lib/installer/installer_core.dart 的 exeName 一起改）
  await File(p.join(stage.path, 'pcl_pw.exe')).rename(p.join(stage.path, 'PCL.PW.exe'));

  // 给外壳补上版本信息与图标：没有这些元数据的匿名 .NET 程序更容易被杀毒软件误判
  final fileVersion = [...version.split('.'), '0', '0'].take(4).join('.');
  final assemblyInfo = File(p.join(dist.path, 'AssemblyInfo.cs'));
  await assemblyInfo.writeAsString('''
using System.Reflection;
[assembly: AssemblyTitle("Pixel World 安装程序")]
[assembly: AssemblyDescription("Pixel World 启动器安装与卸载程序")]
[assembly: AssemblyProduct("Pixel World")]
[assembly: AssemblyCompany("Pixel World")]
[assembly: AssemblyCopyright("Copyright (C) 2026 Pixel World contributors. Apache-2.0.")]
[assembly: AssemblyFileVersion("$fileVersion")]
[assembly: AssemblyInformationalVersion("$version")]
[assembly: AssemblyVersion("$fileVersion")]
''');

  Future<void> compile(String output, [List<String> extra = const []]) => run(csc, [
    '/nologo',
    '/optimize+',
    '/target:winexe',
    '/codepage:65001',
    '/win32manifest:${p.join(root, 'installer', 'shell.manifest')}',
    '/win32icon:${p.join(root, 'windows', 'runner', 'resources', 'app_icon.ico')}',
    '/r:System.IO.Compression.dll',
    '/r:System.Windows.Forms.dll',
    '/r:System.Drawing.dll',
    '/r:System.Core.dll',
    '/out:$output',
    ...extra,
    assemblyInfo.path,
    p.join(root, 'installer', 'Shell.cs'),
    p.join(root, 'installer', 'Theme.cs'),
  ]);

  // 卸载时用的清理程序随程序一起安装
  await compile(p.join(stage.path, 'pw-cleanup.exe'));

  final portable = p.join(dist.path, '$name-portable.zip');
  final payload = p.join(dist.path, 'payload.zip');
  for (final f in [portable, payload]) {
    if (File(f).existsSync()) File(f).deleteSync();
  }
  await run(tar, ['-a', '-c', '-f', portable, '-C', dist.path, name]);
  await run(tar, ['-a', '-c', '-f', payload, '-C', stage.path, '.']);

  final setup = p.join(dist.path, '$name-setup.exe');
  await compile(setup, ['/resource:$payload,payload.zip']);
  File(payload).deleteSync();

  for (final f in [portable, setup]) {
    stdout.writeln('  • ${p.basename(f)}  ${(File(f).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB');
  }
}
