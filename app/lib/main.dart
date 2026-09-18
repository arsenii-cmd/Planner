import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:home_widget/home_widget.dart';

import 'background.dart';
import 'db.dart';
import 'models.dart';
import 'reminders.dart';
import 'screens/calendar_screen.dart';
import 'screens/notes_screen.dart';
import 'screens/pair_screen.dart';
import 'sync.dart';
import 'theme.dart';
import 'widget_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: P.crust,
    statusBarIconBrightness: Brightness.light,
  ));
  await initializeDateFormatting('ru_RU');
  await LocalDb.instance.carryOverTasks(dateKey(DateTime.now()));
  await SyncService.instance.load();
  await Reminders.init();
  runApp(const PlannerApp());
  HomeWidget.registerInteractivityCallback(widgetInteraction);
  // Keep the home-screen widget in step with every local change or sync.
  LocalDb.instance.addListener(WidgetBridge.update);
  WidgetBridge.update();
  // Not awaited: neither should delay the first frame.
  Reminders.requestPermission().then((_) => Reminders.reschedule());
  registerBackgroundSync();
}

class PlannerApp extends StatelessWidget {
  const PlannerApp({super.key});

  @override
  Widget build(BuildContext context) {
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
      theme: buildTheme(),
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

  // Pages are rebuilt on tab switch; CalendarScreen keeps the selected day in static fields.
  final _pages = const [CalendarScreen(), NotesScreen()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SyncService.instance.startPeriodic();
    HomeWidget.initiallyLaunchedFromHomeWidget().then(_fromWidget);
    HomeWidget.widgetClicked.listen(_fromWidget);
  }

  /// "+" in the widget header opens the add sheet on today's calendar.
  void _fromWidget(Uri? uri) {
    if (uri?.host != 'add' || !mounted) return;
    setState(() => _tab = 0);
    CalendarScreen.addRequests.value++;
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
      // The day may have changed while the app was in the background.
      LocalDb.instance.carryOverTasks(dateKey(DateTime.now()));
      SyncService.instance.startPeriodic();
    } else if (state == AppLifecycleState.paused) {
      SyncService.instance.stopPeriodic();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(anim),
              child: child,
            ),
          ),
          child: Text(
            _tab == 0 ? 'Календарь' : 'Заметки',
            key: ValueKey(_tab),
            style: const TextStyle(fontFamily: kFont, fontSize: 24, fontWeight: FontWeight.w700),
          ),
        ),
        actions: const [SyncBadge(), SizedBox(width: 8)],
      ),
      body: PageTransitionSwitcher(
        duration: const Duration(milliseconds: 320),
        transitionBuilder: (child, primary, secondary) => FadeThroughTransition(
          animation: primary,
          secondaryAnimation: secondary,
          fillColor: P.base,
          child: child,
        ),
        child: KeyedSubtree(key: ValueKey(_tab), child: _pages[_tab]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        animationDuration: const Duration(milliseconds: 400),
        onDestinationSelected: (i) {
          if (i == _tab) return;
          HapticFeedback.selectionClick();
          setState(() => _tab = i);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Календарь',
          ),
          NavigationDestination(
            icon: Icon(Icons.sticky_note_2_outlined),
            selectedIcon: Icon(Icons.sticky_note_2),
            label: 'Заметки',
          ),
        ],
      ),
    );
  }
}

/// Sync status in the app bar; spins while syncing, tap opens pairing/sync settings.
class SyncBadge extends StatefulWidget {
  const SyncBadge({super.key});

  @override
  State<SyncBadge> createState() => _SyncBadgeState();
}

class _SyncBadgeState extends State<SyncBadge> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  final sync = SyncService.instance;

  @override
  void initState() {
    super.initState();
    sync.addListener(_onSync);
    _onSync();
  }

  void _onSync() {
    if (sync.state == SyncState.syncing) {
      _spin.repeat();
    } else if (_spin.isAnimating) {
      // Finish the current turn instead of snapping.
      _spin.forward(from: _spin.value).then((_) => _spin.reset());
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    sync.removeListener(_onSync);
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (sync.state) {
      SyncState.unpaired => (Icons.link_off_rounded, P.subtext1),
      SyncState.syncing => (Icons.sync_rounded, P.accent),
      SyncState.ok => (Icons.cloud_done_rounded, P.rose),
      SyncState.offline => (Icons.cloud_off_rounded, P.sand),
      SyncState.error => (Icons.error_outline_rounded, P.red),
      SyncState.idle => (Icons.laptop_rounded, P.accent),
    };
    return IconButton(
      tooltip: 'Синхронизация',
      style: IconButton.styleFrom(backgroundColor: P.mantle),
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairScreen())),
      icon: RotationTransition(
        turns: _spin,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
          child: Icon(icon, key: ValueKey(icon), color: color),
        ),
      ),
    );
  }
}
