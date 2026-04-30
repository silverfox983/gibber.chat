import 'package:flutter/material.dart';
import 'dart:math' as math;

class AudioWaveform extends StatefulWidget {
  final bool isPlaying;
  final Color color;

  const AudioWaveform({
    super.key,
    required this.isPlaying,
    required this.color,
  });

  @override
  State<AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<AudioWaveform> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<double> _baseHeights = List.generate(20, (index) => math.Random().nextDouble() * 20 + 5);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    if (widget.isPlaying) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(AudioWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(20, (index) {
            // Apply a sine wave modulation based on the animation value and index
            final modulation = widget.isPlaying 
                ? math.sin(_controller.value * math.pi * 2 + (index * 0.5)) * 0.5 + 0.5
                : 0.1;
            
            final height = _baseHeights[index] * (0.5 + modulation);

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              width: 3,
              height: height.clamp(4.0, 30.0),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: widget.isPlaying ? 0.9 : 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}
