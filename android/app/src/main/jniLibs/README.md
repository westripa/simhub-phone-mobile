# Native Libraries (`jniLibs`)

`libpjsua2.so` and `libc++_shared.so` are intentionally **not committed** to Git in order to keep the repository lightweight and ensure reproducible GPLv3 corresponding source builds.

Run the reproducible build script from the repository root before building the Android APK:

```bash
./scripts/build-pjsip-android.sh --abis arm64-v8a --sync-java
```
