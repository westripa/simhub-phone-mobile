# SimHub Phone Mobile · Agent Rules

## Release Versioning (Sequential Only)

- **Strictly increment patch version sequentially**: every new release MUST advance the patch version one step at a time (`v0.2.0` -> `v0.2.1` -> `v0.2.2` -> `v0.2.3`).
- **Never skip version numbers**: do not jump patch versions or bump minor/major versions on your own unless the user explicitly instructs a minor or major release.
- **Sync version before tagging `vX.Y.Z`**:
  - Update `version: X.Y.Z+BUILD` in `pubspec.yaml`, keeping `BUILD = X * 10000 + Y * 100 + Z` strictly monotonic so Android package version codes always increase.
  - Ensure `X.Y.Z` matches the release tag `vX.Y.Z` and `.github/workflows/release.yml` expectations before creating and pushing the annotated tag.

## Verification Before Push / Release

- Run static analysis and Flutter unit tests:
  - `flutter analyze`
  - `flutter test`
- When Android native code, manifest, Gradle, or updater installation changes:
  - `flutter build apk --debug --target-platform android-arm64`

## Security & Repository Hygiene

- Never commit Android keystores (`.jks`), keystore passwords, SIP credentials, HA1 hashes, real phone numbers, or private server addresses into Git, commit messages, logs, or responses.
- Keep signing and in-app updater manifest (`latest.json`) generation aligned with [README.md](README.md) and `.github/workflows/release.yml`.
