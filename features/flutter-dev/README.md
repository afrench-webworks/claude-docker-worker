# Flutter Development

Full Flutter SDK with Dart and Android build tools, so Claude Code can create, analyze, build, and test Flutter projects inside the container.

## What's Included

| Tool | Purpose |
|---|---|
| `flutter` | Flutter SDK (stable channel) |
| `dart` | Dart SDK (bundled with Flutter) |
| `adb` | Android Debug Bridge |
| `sdkmanager` | Android SDK component manager |
| OpenJDK 17 | Java runtime for Android builds |
| Android SDK 34 | Build tools and platform for Android targets |
| clang, cmake, ninja | Native compilation for Linux desktop targets |
| libgtk-3-dev | GTK support for Linux desktop apps |

## Permissions

Claude Code is allowed to run `flutter`, `dart`, `adb`, and `sdkmanager`. These permissions are merged into `settings.json` at build time.

## Configuration

This feature has no runtime configuration. Enable it in `features.conf` and rebuild.

## Usage

Once the container is built with this feature enabled, Claude Code can use Flutter directly:

```bash
ssh claude-docker-worker

# Claude can run these in its sessions:
flutter create my_app
flutter analyze
flutter test
flutter build apk
flutter build web
dart analyze
dart format .
```
