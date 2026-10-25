# Android release quality changes for 1.0.7 (11)

These changes prepare version 1.0.7 (11). Its bundle was uploaded to a Google Play
production draft and was not submitted for review as part of that upload.
Signed artifacts, certificate details, mapping files, and Console evidence are
kept outside the public source repository.

## Edge-to-edge and insets

`MainActivity.onCreate` opts into edge-to-edge through AndroidX Core 1.17's
`WindowCompat.enableEdgeToEdge`. Flutter receives the original window insets;
native code does not consume them or apply a second layer of padding. System bar
icons use a light appearance against the application's dark background.

Dart startup explicitly selects `SystemUiMode.edgeToEdge`. The AppBar theme
requests icon brightness without requesting status-bar, navigation-bar, or
navigation-divider colors. The existing `SafeArea` around the chat composer is
preserved, along with the display-cutout protection on the other screens.

Regression tests exercise asymmetric cutout insets, three-button navigation
padding, keyboard resizing, and the actual system-overlay style emitted by an
AppBar. Device verification should also cover gesture navigation, landscape,
video playback, and returning from Android's file picker/settings on API 35/36.

### Flutter compatibility calls in Play's report

The version 10 mapping resolves `A.J.k` to Flutter's
`PlatformPlugin.setSystemChromeSystemUIOverlayStyle`. `P2.a.i` is an R8-generated
API outline for a `Window` color setter. They are not direct application calls.

The installed Flutter 3.41.4 embedding retains deprecated color setters for
older Android compatibility. Its `FlutterActivity` status-bar color call is
guarded to run below API 35. The application's overlay style no longer asks the
embedding to set these colors, but the setter references can still be present
in the generated DEX. A static Play recommendation may therefore remain until
the upstream embedding removes those references; do not claim it has disappeared
without checking the new uploaded artifact. Do not raise minimum Android SDK or
modify Flutter's binaries just to suppress that report.

## Bitmap decoding

`J2.e.i` in version 10 resolves to `file_picker` 8.3.7's `FileUtils.compressImage`,
which used `BitmapFactory.decodeStream` without options. It does not resolve to
the application's canvas code or to battery optimization, despite R8 merging
the method into a class named `SystemUtils`.

The dependency is upgraded to file_picker 12.3.0. Its Android implementation
first reads image bounds with `inJustDecodeBounds`, calculates `inSampleSize`,
and reopens the stream for a sampled decode. Desktop call sites use the new
list-based `pickFiles()` and single-file `pickFile()` API. Android sharing keeps
using the existing system document picker and copies original file bytes;
received/sent photos are not resized by the app.

## R8 and resource shrinking

The build uses AGP 9.0.1 and Gradle 9.3.1. Release builds explicitly enable
minification and resource shrinking with the optimized default ProGuard rules.
Optimized resource shrinking is enabled. Existing upload-key configuration is
preserved.

Older Android library plugins are aligned to a minimum compile SDK of 36 in
`android/build.gradle.kts` through `androidComponents.finalizeDsl`. This handles
AGP 9's library AAR metadata checks without changing their minimum/target SDKs or
editing the user's dependency cache.

`android.builtInKotlin=false` and `android.newDsl=false` retain compatibility with
Flutter 3.41 and the current plugin build scripts. These are migration flags,
not R8 opt-outs. Remove them only after upgrading Flutter and every affected
plugin to a toolchain that supports built-in Kotlin and the new AGP DSL.

The unmaintained disable_battery_optimization plugin is removed because its
Gradle 4-era script uses `jcenter()`. Battery readiness checks and the settings
button now use the application's existing Android method channel. If the
standard battery settings activity is unavailable on an OEM device, the native
implementation falls back to this app's settings page and reports failure if
neither opens.

## Verified local output

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub`: all 23 tests passed, including the three inset/style tests.
- Android signed release AAB and Linux release build: passed.
- bundletool verified package `com.cybersight.sharefilevialan`, version 1.0.7 (11),
  target SDK 36, minimum SDK 24, and the same upload certificate as version 10.
- The actual AAB metadata records AGP 9.0.1. Its effective R8 configuration has
  no `-dontoptimize`, `-dontshrink`, or `-dontobfuscate` directives.
- The DEX still contains the three legacy system-bar setter method names,
  consistent with Flutter/AndroidX compatibility code. That static recommendation
  is not claimed to be cleared. Device UI checks and Play's assessment of the new
  uploaded version remain separate from these local checks.

The signed bundle, inspection result, build summary, checksums, and R8 mapping
are private release artifacts and are not committed to the public repository.

## References

- [Flutter edge-to-edge migration](https://docs.flutter.dev/release/breaking-changes/default-systemuimode-edge-to-edge)
- [AndroidX WindowCompat](https://developer.android.com/reference/androidx/core/view/WindowCompat)
- [file_picker upstream downsampling change](https://pub.dev/packages/file_picker/changelog#1200-beta8)
- [Enable R8 and optimized resource shrinking](https://developer.android.com/topic/performance/app-optimization/enable-app-optimization)
- [Flutter and AGP 9 migration](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin)
