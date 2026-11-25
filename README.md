# SimHub Phone Mobile

<p align="center">
  <img src="assets/branding/simhub-phone-icon.svg" width="96" height="96" alt="SimHub Phone" />
</p>

基于 **Flutter + 原生 `PhoneCore`** 的移动 SIP 软电话客户端（Android 当前可用；iOS 原生核心规划中）。

## 核心特性

- **标准 SIP + TLS + SRTP**：原生层基于 PJSIP 2.17 + OpenSSL 3.0.16（已配置 `verifyServer=true` 并加载 Android 系统 CA 信任库，适配 Android 15 APEX 证书路径）。
- **扫码与配网链接即用**：支持直接扫码或粘贴配网链接（`/api/v1/provisioning/{token}`）、XML / `linphonerc` / JSON 或手动单号导入，无需在安装包内硬编码服务器或账号。
- **Android Keystore 安全落盘**：账号凭据与 Digest `HA1` 使用 Android Keystore AES-256-GCM 加密保存。
- **系统级通话与后台保活**：集成前台常驻服务（`phoneCall|microphone`）、自管 Android Telecom `ConnectionService`、锁屏全屏来电提醒、听筒/扬声器切换、DTMF 与保持/恢复。
- **`PhoneCore` 架构隔离**：Flutter UI 与原生 SIP SDK 通过清晰的 `MethodChannel` / `EventChannel` 解耦。

## 本地开发与构建 Android APK

前置要求：Flutter（stable）、JDK 17、Android SDK + NDK、`swig`、`curl`。

1. 拉取 Dart 依赖并运行静态检查与单元测试：

   ```sh
   flutter pub get
   flutter analyze
   flutter test
   ```

2. 使用对应源码脚本编译 PJSIP 2.17 原生库：

   ```sh
   ./scripts/build-pjsip-android.sh --abis arm64-v8a --sync-java
   ```

3. 构建 Release APK：

   ```sh
   flutter build apk --release --target-platform android-arm64 -PabiFilters=arm64-v8a
   ```

## 配置正式 Android 发布签名（GitHub Secrets）

默认本地无签名配置时会回退使用 debug 签名；公开正式分发前，建议生成正式签名密钥并写入 GitHub Repository Secrets（否则不同签名间无法覆盖安装升级）：

```sh
keytool -genkey -v -keystore simhub-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias simhub
base64 -w 0 simhub-release.jks
```

在仓库 **Settings -> Secrets and variables -> Actions** 中配置以下 4 个 Secret：

- `ANDROID_KEYSTORE_BASE64`（上面生成的 base64 内容）
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`（如 `simhub`）
- `ANDROID_KEY_PASSWORD`

## GitHub Actions CI/CD

- **CI（`.github/workflows/ci.yml`）**：每次 push 到 `main` 或发起 PR 时自动运行 `flutter analyze`、`flutter test`，并缓存/源码编译 PJSIP 验证 `arm64-v8a` APK 可构建。
- **发版（`.github/workflows/release.yml`）**：推送版本 tag（如 `git tag v0.1.0 && git push origin v0.1.0`）或在 Actions 页面手动触发，自动构建 Release APK、生成 `SHA256SUMS.txt` 并发布至 GitHub Releases。

## iOS 说明

`ios/` 目前包含 Flutter 工程壳与统一应用图标资源，原生 Swift `PhoneCore`（CallKit / AVAudioSession / PushKit）属于下一阶段计划；未来如需上架 Apple App Store，可通过采购 PJSIP 商业授权或基于 `PhoneCore` 抽象切换至 BSD 许可内核（如 `baresip + libre`）。

## 开源协议

本项目以 **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** 开源，完整条款见 [LICENSE](LICENSE)，第三方依赖与源码构建说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
