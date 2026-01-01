import 'package:flutter/material.dart';
import 'status_tab.dart';
import 'settings_tab.dart';
import 'about_tab.dart';
import '../services/storage.dart';
import '../services/compression_manager.dart';
import '../models/job_status.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int? _index; // null = deciding
  late final PageController _pageController;

  final _storage = StorageService();
  final _mgr = CompressionManager();
  final _statusKey = GlobalKey<StatusTabState>();

  @override
  void initState() {
    super.initState();
    _decideInitialTab();
    _autoResumeIfNeeded();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _autoResumeIfNeeded() async {
    final jobs = await _storage.loadJobs();
    final anyInProgress =
        jobs.values.any((j) => j.status == JobStatus.inProgress);
    if (anyInProgress && !_mgr.isRunning) {
      // ignore: unawaited_futures
      _mgr.start();
    }
  }

  Future<void> _decideInitialTab() async {
    if (_mgr.isRunning) {
      _index = 0;
    } else {
      final opts = await _storage.loadOptions();
      final selected =
          (opts['selectedFolders'] as List?)?.cast<String>() ?? const <String>[];
      _index = selected.isEmpty ? 1 : 0;
    }

    _pageController = PageController(initialPage: _index!);

    if (mounted) setState(() {});
    if (_index == 0) {
      _statusKey.currentState?.refreshJobs();
    }
  }

  void _goToStatusTab() {
    setState(() => _index = 0);
    _pageController.animateToPage(
      0,
      duration: const Duration(milliseconds: 10),
      curve: Curves.fastEaseInToSlowEaseOut,
    );
    _statusKey.currentState?.refreshJobs();
  }

  @override
  Widget build(BuildContext context) {
    if (_index == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (i) {
          setState(() => _index = i);
          if (i == 0) _statusKey.currentState?.refreshJobs();
        },
        children: [
          StatusTab(key: _statusKey),
          SettingsTab(goToStatusTab: _goToStatusTab),
          const AboutTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index!,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          _pageController.animateToPage(
            i,
            duration: const Duration(milliseconds: 10),
            curve: Curves.fastEaseInToSlowEaseOut,
          );
          if (i == 0) _statusKey.currentState?.refreshJobs();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Status',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
          NavigationDestination(
            icon: Icon(Icons.info_outline),
            selectedIcon: Icon(Icons.info),
            label: 'About',
          ),
        ],
      ),
    );
  }
}
