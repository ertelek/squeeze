import 'package:flutter/material.dart';
import '../services/storage.dart';
import 'home_shell.dart';
import 'onboarding_screen.dart';

class AppEntry extends StatefulWidget {
  const AppEntry({super.key});

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> {
  final _storage = StorageService();
  bool? _seen;
  bool _goToSettings = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seen = await _storage.loadOnboardingSeen();
    if (mounted) setState(() => _seen = seen);
  }

  @override
  Widget build(BuildContext context) {
    if (_seen == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_seen == true) {
      return HomeShell(initialTabIndex: _goToSettings ? 1 : null);
    }

    return OnboardingScreen(
      onDone: ({required bool goToSettings}) {
        if (!mounted) return;
        setState(() {
          _seen = true;
          _goToSettings = goToSettings;
        });
      },
    );
  }
}
