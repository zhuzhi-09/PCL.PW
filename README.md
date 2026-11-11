# Pixel World

Pixel World 是一个跨平台的 Minecraft 启动器，本项目为轻度使用 PCL 仓储库，界面布局参考 [PCL 社区版（PCL-CE）](https://www.pclc.cc)，视觉上遵循 Google 的 Material Design 3 设计语言，使用 Flutter 开发，目标平台为 Windows、macOS、Linux 与 Android。

> [!IMPORTANT]
> **Pixel World 是第三方 Minecraft 启动器，本项目为轻度使用 [Plain Craft Launcher（PCL）](https://github.com/Meloong-Git/PCL) 仓储库**，由第三方开发和维护，与 PCL 及其作者龙腾猫跃无关，也不代表 PCL 官方。请勿就本软件的问题打扰 PCL 作者。

本项目遵循 PCL 的[《PCL 存储库合理使用指南》](PCL-GUIDE.md)，保留必要的 PCL 署名、兼容说明，并公开源代码。

## 状态

项目仍在开发中，已经可以日常使用。

| 平台 | 状态 |
|---|---|
| Windows | 可用 |
| Android | 可用（需要 Android 8.0 及以上、64 位 ARM），游戏运行时见 [android/runtime](android/runtime/NOTICE.md) |
| macOS | 可用（macOS 12 及以上，Apple 芯片与 Intel 通用，Apple 芯片上 1.12.2 到最新版本均已实测）；没有经过 Apple 公证 |
| Linux | 测试中（Nightly 提供 x64 tar.gz、deb、rpm、AppImage 与 Arch 包，需要 Ubuntu 24.04 及以上） |

### 已支持

- **版本**：下载与安装原版（正式版、快照、远古版、愚人节版本）；版本选择、改名、复制、删除；版本隔离（与 PCL-CE 规则相同）；每个版本单独的 Java、内存、参数等设置。
- **模组加载器**：Forge、NeoForge、Fabric、Quilt、Legacy Fabric、LiteLoader、Cleanroom、OptiFine（独立安装，或作为模组与加载器一起安装）、LabyMod。安卓上暂时不能安装需要运行安装器的 Forge、NeoForge、Cleanroom 与 OptiFine，见「下一步」。
- **资源**：从 Modrinth 搜索并安装模组、光影包、资源包、数据包，自动安装必需的前置模组；模组启用与禁用；存档、截图等文件管理。
- **下载**：官方源与 BMCLAPI 镜像，失败自动回退；多线程下载；SHA-1 校验；结尾的慢连接自动换节点。
- **账户**：微软正版登录、离线账户与外置登录；账户在 Windows 上用 DPAPI 加密保存。
- **Java**：自动查找本机 Java，缺少时按版本需要自动下载。
- **启动与排错**：启动游戏、游戏日志、崩溃分析；可选的 AI 排障助手（自填接口），可以查看日志、搜索并安装模组、修改配置文件、备份与恢复，每次修改都需要你确认。
- **从 PCL-CE 迁移**：导入全局设置、游戏文件夹与账户；直接使用 PCL-CE 的版本文件夹与版本设置。
- **安卓**：内置游戏运行时，支持 1.0 到 26.x 的 Java 版；渲染器可选 MobileGlues、Zink（Adreno 上使用 Turnip）、系统 GLES；触屏操作按键与摇杆。

### 下一步

- 安卓上运行 jar：在手机上运行 Forge、NeoForge、Cleanroom、OptiFine 的安装器，也可以运行自选的 jar 文件。
- 安卓与 macOS 上用系统密钥库（Android Keystore、钥匙串）加密账户与 API Key。

### 计划支持

- Linux 桌面集成（.deb/AppImage）与更多发行版验证。
- 整合包安装（Modrinth、CurseForge）。
- 安卓：手柄、自定义按键布局，更多渲染器选项。

## 下载

在 [Releases](https://github.com/zhuzhi-09/PixelWorld/releases) 页面下载：

- **正式版**：推送 `v*` 标签时自动构建发布。
- **Nightly**：`main` 分支每次更新后自动构建，发布为名为 `nightly` 的预发布版本，包含最新改动，可能不稳定。

## 构建

需要 Flutter 3.47 或更高版本。Windows 构建另需 Visual Studio 2022 的“使用 C++ 的桌面开发”工作负载（含 C++ CMake 工具）。

```bash
flutter pub get
flutter run -d windows
flutter build windows --release --no-tree-shake-icons
```

发布构建需要加 `--no-tree-shake-icons`：当前 Flutter 版本裁剪图标字体时会漏掉部分图标。

打包 Windows 安装程序与便携版（输出到 `dist/`）：

```bash
dart run tool/build_installer.dart
```

安装程序只为当前用户安装，不需要管理员权限；外壳用系统自带的 .NET Framework 编译器编译。

安卓版（arm64）：

```bash
flutter build apk --release --target-platform android-arm64 --no-tree-shake-icons
```

自动发布由 [.github/workflows/release.yml](.github/workflows/release.yml) 完成。安卓的发布签名来自仓库 Secrets：`ANDROID_KEYSTORE_BASE64`（密钥库的 base64）、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`；没有配置时使用调试签名。

## 许可证

Pixel World 自身的代码以 [Apache-2.0](LICENSE) 协议开源。PCL 的相关规则见 [PCL-GUIDE.md](PCL-GUIDE.md)。

Minecraft 是 Mojang Studios 的商标。本软件不是官方 Minecraft 产品，未经 Mojang 或 Microsoft 批准，也与其无关。

## 赞助作者

你可以在爱发电赞助 Pixel World 的开发者竹纸：[afdian.com/a/Paper_Zhu](https://afdian.com/a/Paper_Zhu)。

感谢爱发电提供平台支持！
