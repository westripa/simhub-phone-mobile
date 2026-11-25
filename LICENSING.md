# 许可证与平台分发说明

- 本仓库（SimHub Phone Mobile）以 **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** 公开开源（见 [LICENSE](LICENSE)）。
- Android 端当前使用 **PJSIP 2.17（GPLv2+）** 作为原生通话核心，并通过 [scripts/build-pjsip-android.sh](scripts/build-pjsip-android.sh) 提供完整、可复现的对应源码构建流程。
- 业务后台（SIP 服务器 / 语音网关）仅通过标准 SIP / TLS / SRTP / HTTP 协议与本客户端通信，属于独立程序，不因客户端使用 GPL 而受传染。
- 未来若需以闭源方式分发或上架 **Apple App Store**（App Store 条款与 GPL 存在兼容性冲突），可保持 Flutter UI 与 `PhoneCore` 接口不变，采取以下任一路径：
  1. 采购 PJSIP 或 Liblinphone 商业授权；
  2. 将原生 `PhoneCore` 迁移至宽松许可协议（如 BSD-3-Clause 的 `baresip + libre`）。
