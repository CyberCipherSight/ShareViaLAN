# Security and privacy

ShareViaLAN uses UDP discovery and TCP connections on the local network. It does
not implement end-to-end encryption or authenticated TLS for these connections.
Use it on networks you trust; approval dialogs and group invite codes do not
provide protection against a hostile network operator.

Discovery advertises a display name and an app-generated peer identifier to
nearby peers. Preferences and optional chat history are stored locally. These
runtime files are not part of the source repository. The application contains
no advertising SDK or advertising-ID integration.

Opening a received file requires an explicit action. Android still controls APK
installation, and desktop systems use their configured application associations.
Review files from other devices before opening or installing them.

Do not post vulnerabilities containing private data or credentials in a public
issue. Use GitHub's private vulnerability reporting feature if it is enabled.
Otherwise open a minimal issue asking for a private reporting channel without
including exploit details or personal information.

Release signing keys, passwords, service credentials, and local device state are
not distributed with the source. Forks must use their own signing keys and
application identities for distribution. Do not attach private configuration,
chat history, received files, or unredacted logs to bug reports.
