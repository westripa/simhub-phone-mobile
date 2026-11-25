# SimHub Phone 移动端架构

## 目标与分层

同一套 Flutter UI 通过 `PhoneCore` 抽象隔离底层原生 SIP/媒体引擎，方便在不改业务界面的前提下替换传输核心或补齐 iOS 实现：

```text
Flutter UI（多号池 / 配网导入 / 拨号 / 通话 / 历史 / 设置）
        │ MethodChannel (simhub.phone/core) & EventChannel (simhub.phone/events)
        ▼
Native Core（Android Kotlin + PJSIP 2.17 / iOS Swift 待实现）
  ├─ SIP over TLS（加载系统 CA + verifyServer） & SRTP
  ├─ 音频焦点、听筒 / 扬声器 / 蓝牙路由
  ├─ 前台服务保活（phoneCall|microphone） & 锁屏全屏来电提醒
  └─ Android Telecom self-managed ConnectionService / iOS CallKit（规划中）
```

## 架构原则

1. **状态唯一来源在 Native Core**：Flutter 侧只作为状态镜像与操作触发入口，并持有 `FakePhoneCore` 用于无原生依赖的 UI 测试。
2. **音频帧与 RTP 不经过 Dart**：媒体流全部在原生层处理，确保后台与锁屏通话稳定。
3. **凭据本地加密保存**：`PhoneAccountStore` 使用 `AndroidKeyStore`（AES-256-GCM）加密持久化 SIP 凭据；不将账号或服务器地址编入安装包。
