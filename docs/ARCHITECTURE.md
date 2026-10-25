# ShareViaLAN architecture

ShareViaLAN is a Flutter application for Android, Linux, and Windows. Its UI,
discovery, messaging, transfer state, and local persistence are written in Dart.
Android-specific system integrations use a Kotlin method channel.

## Application and preferences

- `lib/main.dart`: app startup, peer dashboard, chats, transfer controls, canvas,
  Settings, and About screens.
- `lib/setup_screen.dart`: display-name setup.
- `lib/chat_preferences.dart`: global and per-chat feature preferences in
  SharedPreferences.
- `lib/chat_history_store.dart`: optional persistent chat history in Hive.

A persistent internal peer ID lets discovery recognize a device across IP
changes and associates it with conversations and permissions. It is not a
hardware identifier and is not displayed in Settings. Removing this internal ID
would break those associations. This source tree has no installation-ID UI,
network-map screen, premium section, ad SDK, or GitHub advertisement request.
The GitHub links in About open project/download pages only when tapped.

## Network and transfers

- `lib/discovery.dart`: UDP discovery on port 9001, network interface selection,
  announcements, and peer freshness.
- `lib/lan_protocol.dart`: protocol and version constants.
- `lib/messaging.dart`: TCP communication on port 9002, connection approval,
  conversations, file offers, transfer progress, acknowledgements, pause/resume,
  and progressive video streams.

Receiving a file requires an accepted offer, or a temporary accept-all rule
chosen by the receiver. Incoming data is staged as a partial file and its byte
count checked before publication. Completed files are published to Android
Downloads through MediaStore on Android 10+, or public storage with runtime
permission on Android 6–9. Desktop downloads use path_provider to honor the
configured Downloads location, with conventional folders as a fallback.

`lib/file_names.dart` removes path components, invalid filename characters,
Windows reserved basenames, and trailing dots/spaces. UTF-8 byte limits keep
long multilingual filenames usable across filesystems while preserving ordinary
extensions. Existing duplicate-name suffix handling remains in the transfer
service and Android publisher.

## Opening files and platform integration

`lib/received_file_opener.dart` checks that a file is still present and converts
file-opening failures into messages with recovery steps. Linux and Windows use
the existing open_file desktop implementations and system file associations.

On Android, `lib/lan_platform_channel.dart` calls `MainActivity.kt`. Opening a
file uses the application's FileProvider with temporary read permission rather
than the open_file plugin's broad storage-permission checks. APKs use the Android
package MIME type. Android 8+ installation permission is checked only when the
user opens an APK; the app opens the per-source system settings screen when
needed, rechecks the permission when the user returns, and then launches the
installer. The pending APK path survives activity recreation. Denied permission,
missing files/viewers, and device restrictions return explicit errors. Installation
still requires the user's confirmation in the system installer.

The same Kotlin channel supports the system picker, caching picked content,
download publication, multicast/wake locks, sounds, and external video playback.
`lib/permission_manager.dart` and `lib/connection_readiness_screen.dart` handle
platform permission and LAN/firewall diagnostics. APK-install permission is
optional and does not block ordinary messaging or file sharing.

`lib/external_video_launcher.dart`, `lib/stream_video_player.dart`,
`lib/lan_notifications.dart`, and `lib/lan_sounds.dart` cover playback and alerts.
Desktop packaging lives under `packaging/linux` and `packaging/windows`.

## Validation

Run `flutter analyze` and `flutter test`. The regression tests cover portable
filenames, missing files, Android file-opening result handling, and Linux/Windows
opener dispatch, alongside the existing setup, preferences, and discovery tests.
The file-opening tests mock platform calls; they do not exercise real installers.

For device verification, receive an APK on Android 8+, open it with installation
permission disabled, allow it in Settings, and return to the installer. Repeat
with permission denied, an uppercase `.APK`, an installed viewer missing, and a
received file deleted outside the app. On Android 6–9, test public download saves
with storage permission both allowed and denied. On Linux/Windows, test relocated
Downloads folders, duplicate names, Unicode names, and files without an associated
application. Build and exercise Windows installers on Windows.
