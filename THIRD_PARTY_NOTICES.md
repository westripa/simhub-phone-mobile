# 第三方组件与对应源码声明

本项目整体按 **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** 发布（详见 [LICENSE](LICENSE)），并包含或动态链接以下第三方开源组件：

| 组件 | 版本 | 许可证 | 用途说明 |
|---|---|---|---|
| [PJSIP / pjproject](https://github.com/pjsip/pjproject/tree/2.17) | `2.17` | GPLv2+ | Android 原生 SIP / RTP / SRTP / TLS 通话引擎（通过 SWIG JNI `libpjsua2.so` 集成） |
| [OpenSSL](https://github.com/openssl/openssl/releases/tag/openssl-3.0.16) | `3.0.16` | Apache-2.0 | PJSIP TLS / SRTP 密码学支持库 |
| [libsrtp](https://github.com/cisco/libsrtp)（随 PJSIP 构建） | `2.1.0` | BSD-3-Clause | SRTP 媒体加密 |
| [ZXing Core](https://github.com/zxing/zxing) | `3.5.3` | Apache-2.0 | Android 扫码配网二维码解码 |
| Flutter / Dart / `material_ui` | 以 `pubspec.yaml` 为准 | BSD-3-Clause / MIT | 跨平台 UI 框架与组件库 |

## PJSIP 对应源码构建

为保证仓库轻量化与完整的可复现 GPL 对应源码要求，预编译 `.so` 不直接提交至 Git 仓库，所有构建均通过 [scripts/build-pjsip-android.sh](scripts/build-pjsip-android.sh) 从上述官方固定版本源码构建。
