import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class OnboardingLoopVideo extends StatefulWidget {
  const OnboardingLoopVideo({
    super.key,
    required this.assetPath,
    this.borderRadius = BorderRadius.zero,
    this.fit = BoxFit.cover,
    this.showLoadingSpinner = true,
  });

  final String assetPath;
  final BorderRadius borderRadius;
  final BoxFit fit;
  final bool showLoadingSpinner;

  @override
  State<OnboardingLoopVideo> createState() => _OnboardingLoopVideoState();
}

class _OnboardingLoopVideoState extends State<OnboardingLoopVideo> {
  late final VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();

    _controller = VideoPlayerController.asset(widget.assetPath)
      ..setLooping(true) // ✅ loop forever
      ..setVolume(0.0); // ✅ mute (recommended for onboarding)

    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
      _controller.play(); // ✅ auto-play
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _controller.value.isInitialized;

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: initialized
          ? FittedBox(
              fit: widget.fit,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: _controller.value.size.width,
                height: _controller.value.size.height,
                child: VideoPlayer(_controller),
              ),
            )
          : widget.showLoadingSpinner
              ? const SizedBox.expand(
                  child: Center(child: CircularProgressIndicator()),
                )
              : const SizedBox.expand(),
    );
  }
}
