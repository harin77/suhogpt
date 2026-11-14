import 'package:flutter/material.dart';

import 'dart:io';
import 'dart:ui';

import 'models.dart';
import 'screens/chat_screen.dart';
import 'screens/setup_screen.dart';
import 'services/engine.dart';

void main() => runApp(const SuhoApp());

class SuhoApp extends StatefulWidget {
  const SuhoApp({super.key});
  @override
  State<SuhoApp> createState() => _SuhoAppState();
}

class _SuhoAppState extends State<SuhoApp> {
  // Stop llama-server when the window closes, so it doesn't keep using RAM/VRAM.
  late final AppLifecycleListener _life = AppLifecycleListener(onExitRequested: () async {
    await Engine.instance.stop();
    return AppExitResponse.exit;
  });

  @override
  void initState() {
    super.initState();
    _life;
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  ThemeData _theme(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF10A37F),
      brightness: b,
    ).copyWith(
      surface: dark ? const Color(0xFF212121) : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF171717) : const Color(0xFFF9F9F9),
      surfaceContainer: dark ? const Color(0xFF2F2F2F) : const Color(0xFFF4F4F4),
      surfaceContainerHigh: dark ? const Color(0xFF3A3A3A) : const Color(0xFFECECEC),
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
      visualDensity: VisualDensity.compact,
      listTileTheme: const ListTileThemeData(dense: true, minVerticalPadding: 4),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Suho AI',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: const Boot(),
      );
}

/// Decides on start-up: everything ready -> start engine -> chat, otherwise -> setup wizard.
class Boot extends StatefulWidget {
  const Boot({super.key});
  @override
  State<Boot> createState() => _BootState();
}

class _BootState extends State<Boot> {
  String status = 'Checking llama.cpp...';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    await Engine.killStale();
    final settings = await Store.loadSettings();
    final engine = Engine.instance;
    engine.binary = await Engine.pickBest();
    String? error;
    var ready = engine.binary != null && settings.modelPath.isNotEmpty && await File(settings.modelPath).exists();
    if (ready) {
      setState(() => status = 'Loading Suho on ${engine.binary!.label}...');
      error = await engine.start(settings);
      ready = error == null;
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ready ? ChatScreen(settings: settings) : SetupScreen(startError: error),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SuhoLogo(size: 64),
            const SizedBox(height: 24),
            const SizedBox(width: 160, child: LinearProgressIndicator()),
            const SizedBox(height: 12),
            Text(status),
          ]),
        ),
      );
}

class SuhoLogo extends StatelessWidget {
  final double size;
  const SuhoLogo({super.key, this.size = 32});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(colors: [Color(0xFF10A37F), Color(0xFF0B6E99)]),
          boxShadow: [BoxShadow(color: const Color(0xFF10A37F).withValues(alpha: 0.35), blurRadius: size / 3)],
        ),
        alignment: Alignment.center,
        child: Text('S',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.5)),
      );
}
