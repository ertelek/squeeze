import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/storage.dart';

class OnboardingStepData {
  final IconData icon;
  final String title;
  final String description;

  /// Optional image (e.g. AssetImage('assets/onboarding/step1.jpg'))
  final ImageProvider? image;

  /// Optional looping video asset (e.g. 'assets/onboarding/step2.mp4')
  final String? videoAsset;

  const OnboardingStepData({
    required this.icon,
    required this.title,
    required this.description,
    this.image,
    this.videoAsset,
  }) : assert(
          image == null || videoAsset == null,
          'Provide either image OR videoAsset for a step, not both.',
        );

  bool get hasMedia => image != null || videoAsset != null;
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final void Function({required bool goToSettings}) onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _page = PageController();
  int _index = 0;

  static const List<OnboardingStepData> _steps = [
    OnboardingStepData(
      icon: Icons.waving_hand_outlined,
      title: 'Welcome to Squeeze!',
      description: 'Let’s show you how to get started.',
      // no media -> centered card content
    ),
    OnboardingStepData(
      icon: Icons.video_library_outlined,
      title: 'Pick albums',
      description: 'Choose albums with large videos — or select all albums.',
      image: AssetImage('assets/onboarding/step1.jpg'),
    ),
    OnboardingStepData(
      icon: Icons.auto_awesome_outlined,
      title: 'Start compression',
      description:
          'Tap Start compression and watch the magic happen. You’ll get a progress notification.',
      videoAsset: 'assets/onboarding/step2.mp4', // video goes here
    ),
    OnboardingStepData(
      icon: Icons.delete_outline,
      title: 'Clear old files',
      description: 'When it\'s done, tap Clear old files to save space.',
      image: AssetImage('assets/onboarding/step3.jpg'),
    ),
  ];

  bool get _isLast => _index == _steps.length - 1;

  Future<void> _finish({required bool goToSettings}) async {
    await StorageService().saveOnboardingSeen(true);
    widget.onDone(goToSettings: goToSettings);
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            children: [
              // Top bar
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => _finish(goToSettings: false),
                    child: const Text('Skip'),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Pages
              Expanded(
                child: PageView.builder(
                  controller: _page,
                  itemCount: _steps.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => _StepCard(
                    step: _steps[i],
                    isActive: i == _index, // ✅ pause videos offscreen
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Dots + buttons
              Row(
                children: [
                  _Dots(count: _steps.length, index: _index),
                  const Spacer(),
                  if (_index > 0)
                    TextButton(
                      onPressed: () {
                        _page.previousPage(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                        );
                      },
                      child: const Text('Back'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.primary,
                      foregroundColor: cs.onPrimary,
                    ),
                    onPressed: () async {
                      if (_isLast) {
                        await _finish(goToSettings: true);
                      } else {
                        _page.nextPage(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                    child: Text(_isLast ? 'Get started' : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.step, required this.isActive});
  final OnboardingStepData step;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const cardRadius = 20.0;

    // ✅ No media: center content vertically in the page/card.
    if (!step.hasMedia) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            elevation: 0,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(cardRadius),
              side: BorderSide(color: cs.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _IconBubble(icon: step.icon),
                    const SizedBox(height: 14),
                    Text(
                      step.title,
                      textAlign: TextAlign.center,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      step.description,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            height: 1.35,
                            color: Colors.black87,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    // ✅ Has media: media dominates, text area scrolls if needed.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(cardRadius),
            side: BorderSide(color: cs.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxH = constraints.maxHeight;

              // Big media, but clamped so it won't overflow on small screens.
              final mediaH = (maxH * 0.62).clamp(200.0, 460.0);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: mediaH,
                    child: _Media(
                      step: step,
                      isActive: isActive,
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                      child: Column(
                        children: [
                          _IconBubble(icon: step.icon),
                          const SizedBox(height: 12),
                          Text(
                            step.title,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            step.description,
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  height: 1.35,
                                  color: Colors.black87,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Media extends StatelessWidget {
  const _Media({required this.step, required this.isActive});
  final OnboardingStepData step;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (step.videoAsset != null) {
      return Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(12), // 👈 adjust
          child: OnboardingLoopVideo(
            assetPath: step.videoAsset!,
            isActive: isActive,
            backgroundColor: Colors.white,
          ),
        ),
      );
    }

    if (step.image != null) {
      return Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(12), // 👈 adjust
          child: Image(
            image: step.image!,
            fit: BoxFit.fitHeight,
          ),
        ),
      );
    }

    return Container(color: cs.surface);
  }
}

class _IconBubble extends StatelessWidget {
  const _IconBubble({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(
        icon,
        size: 26,
        color: cs.onPrimaryContainer,
      ),
    );
  }
}

/// Looping, muted onboarding video (asset) that pauses when off-screen.
class OnboardingLoopVideo extends StatefulWidget {
  const OnboardingLoopVideo({
    super.key,
    required this.assetPath,
    required this.isActive,
    this.backgroundColor,
  });

  final String assetPath;
  final bool isActive;
  final Color? backgroundColor;

  @override
  State<OnboardingLoopVideo> createState() => _OnboardingLoopVideoState();
}

class _OnboardingLoopVideoState extends State<OnboardingLoopVideo> {
  late final VideoPlayerController _controller;
  bool _initStarted = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset(widget.assetPath);
    _init();
  }

  Future<void> _init() async {
    if (_initStarted) return;
    _initStarted = true;

    await _controller.setLooping(true);
    await _controller.setVolume(0.0);
    await _controller.initialize();

    if (!mounted) return;

    setState(() {});
    _syncPlayback();
  }

  @override
  void didUpdateWidget(covariant OnboardingLoopVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _syncPlayback();
    }
    if (oldWidget.assetPath != widget.assetPath) {
      // In this onboarding use-case assetPath shouldn't change for the same widget,
      // but handle it safely just in case.
      _controller.pause();
      _controller.dispose();
    }
  }

  void _syncPlayback() {
    if (!_controller.value.isInitialized) return;
    if (widget.isActive) {
      _controller.play();
    } else {
      _controller.pause();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return Container(
        color: widget.backgroundColor ?? Colors.black12,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
      );
    }

    // Fill the available media box while preserving aspect ratio.
    return Container(
      color: widget.backgroundColor ?? Colors.black,
      child: FittedBox(
        fit: BoxFit.fitHeight,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: _controller.value.size.width,
          height: _controller.value.size.height,
          child: VideoPlayer(_controller),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: List.generate(count, (i) {
        final selected = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.only(right: 6),
          height: 8,
          width: selected ? 18 : 8,
          decoration: BoxDecoration(
            color: selected ? cs.primary : cs.outlineVariant,
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}
