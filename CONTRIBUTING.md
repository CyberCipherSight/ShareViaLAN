# Contributing to ShareViaLAN

Use the setup steps in [README](README.md). Flutter 3.41.4 is the tested SDK;
`pubspec.lock` pins the application dependencies.

Before opening a pull request, run:

```bash
flutter pub get
flutter analyze
flutter test
```

Build the platform affected by your change. Windows builds require Windows and
the Visual Studio C++ workload. Linux builds require GTK 3 development tools.
Android development builds use `flutter build apk --debug`; contributors do not
need the official app's upload key. Keep the Gradle wrapper checked in.

For file-transfer changes, exercise paths with spaces and Unicode, duplicate
filenames, relocated Downloads folders, unavailable viewers, and permission
denials. Unit tests mock platform integrations; also test actual system dialogs
on the affected operating systems. See [Architecture](docs/ARCHITECTURE.md).

Never commit signing keys, `android/key.properties`, SDK paths in
`android/local.properties`, credentials, chat databases, received files, device
identifiers, or logs/screenshots containing personal information. Replace real
names, addresses, paths, and network information in reports with examples.

Report ordinary bugs through GitHub Issues with the app version, operating
system, expected behavior, and reproduction steps. Follow [SECURITY](SECURITY.md)
for sensitive reports. New contributions are made under the project's PolyForm
Noncommercial 1.0.0 license. Submit only work you have permission to contribute
under those terms, and retain third-party copyright and license notices. See
[Licensing](LICENSING.md) for previously published MIT versions.
