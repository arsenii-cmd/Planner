# Planner for Android

The phone half of [Planner](../README.md): a calendar, day tasks and quick notes that sync with
`plannerd` on your own machine. Built with Flutter.

- **Calendar and tasks** — events with a time, tasks for a day, repeating series.
- **Notes** — quick notes with a title and text.
- **Sync** — pairs with `plannerd` by scanning a QR code; over the LAN it pins the daemon's
  self-signed certificate and finds it again by mDNS when the address changes, or talks to a
  server-mode daemon over HTTPS with end-to-end encryption. Syncs in the background.
- **Reminders** — local notifications for events with a reminder set.
- **Widget** — today's list on the home screen, with an add button.

## Building

```sh
flutter pub get
flutter build apk --release    # build/app/outputs/flutter-apk/app-release.apk
```

Then open the app, tap pair and scan what `plannerd pair` prints.

| Path | What it is |
| --- | --- |
| `lib/main.dart` | App shell: the calendar and notes tabs |
| `lib/screens/` | Calendar, item editor, notes, pairing |
| `lib/db.dart`, `lib/models.dart` | Local SQLite storage and the item model |
| `lib/sync.dart`, `lib/crypto.dart` | Sync with `plannerd`, end-to-end encryption |
| `lib/background.dart`, `lib/reminders.dart` | Background sync, notifications |
| `lib/widget_bridge.dart`, `android/.../TodayWidgetProvider.kt` | The home-screen widget |
