import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'background.dart';
import 'reminders.dart';
import 'screens/calendar_screen.dart';
import 'screens/notes_screen.dart';
import 'screens/pair_screen.dart';
import 'sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru_RU');
  await SyncService.instance.load();
  await Reminders.init();
  runApp(const PlannerApp());
  // Not awaited: neither should delay the first frame.
  Reminders.requestPermission().then((_) => Reminders.reschedule());
  registerBackgroundSync();
}

// Palette of the laptop's peach Serpantinum theme.
const kAccent = Color(0xFFFFB5A0);
const kBackground = Color(0xFF1A1110);

class PlannerApp extends StatelessWidget {
  const PlannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: kAccent,
      brightness: Brightness.dark,
    ).copyWith(primary: kAccent, surface: kBackground);
    return MaterialApp(
      title: 'Planner',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(colorScheme: scheme, useMaterial3: true, scaffoldBackgroundColor: kBackground),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SyncService.instance.startPeriodic();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SyncService.instance.stopPeriodic();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SyncService.instance.startPeriodic();
    } else if (state == AppLifecycleState.paused) {
      SyncService.instance.stopPeriodic();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tab == 0 ? 'Календарь' : 'Заметки'),
        backgroundColor: kBackground,
        actions: const [SyncBadge()],
      ),
      body: IndexedStack(
        index: _tab,
        children: const [CalendarScreen(), NotesScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.calendar_month_outlined), selectedIcon: Icon(Icons.calendar_month), label: 'Календарь'),
          NavigationDestination(icon: Icon(Icons.sticky_note_2_outlined), selectedIcon: Icon(Icons.sticky_note_2), label: 'Заметки'),
        ],
      ),
    );
  }
}

/// Sync status in the app bar; tap opens pairing/sync settings.
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final (icon, color) = switch (sync.state) {
          SyncState.unpaired => (Icons.link_off, Colors.grey),
          SyncState.syncing => (Icons.sync, kAccent),
          SyncState.ok => (Icons.cloud_done_outlined, Colors.greenAccent),
          SyncState.offline => (Icons.wifi_off, Colors.orangeAccent),
          SyncState.error => (Icons.error_outline, Colors.redAccent),
          SyncState.idle => (Icons.laptop, kAccent),
        };
        return IconButton(
          icon: Icon(icon, color: color),
          tooltip: 'Синхронизация',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PairScreen()),
          ),
        );
      },
    );
  }
}
