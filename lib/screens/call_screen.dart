import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;
import '../providers/call_provider.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _waveController;
  late CallProvider _callProvider;
  Timer? _durationTimer;
  Duration _callDuration = Duration.zero;
  bool _showDtmfPad = false;
  bool get isCallActive => _callProvider.state == CallState.active;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();

    _callProvider = Provider.of<CallProvider>(context, listen: false);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _callProvider.addListener(_handleCallStateChanges);
      if (_callProvider.state == CallState.active) {
        _startTimer();
      }
    });
  }

  void _handleCallStateChanges() {
    if (!mounted) return;
    if (_callProvider.state == CallState.active) {
      _startTimer();
    } else if (_callProvider.state == CallState.idle) {
      _stopTimer();
      Navigator.of(context).maybePop();
    }
    setState(() {});
  }

  void _startTimer() {
    if (_durationTimer != null) return;
    _callDuration = Duration.zero;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _callDuration += const Duration(seconds: 1);
        });
      }
    });
  }

  void _stopTimer() {
    _durationTimer?.cancel();
    _durationTimer = null;
  }

  @override
  void dispose() {
    _callProvider.removeListener(_handleCallStateChanges);
    _stopTimer();
    _pulseController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = Provider.of<CallProvider>(context);
    final isCallActive = call.state == CallState.active;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Background layer: Gradient
          if (!call.isVideo || !isCallActive)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      theme.scaffoldBackgroundColor,
                      theme.colorScheme.primary.withValues(alpha: 0.2),
                      theme.colorScheme.surface,
                    ],
                  ),
                ),
              ),
            ),

          // CRITICAL: RTCVideoView - ALWAYS on top when stream exists
          if (call.remoteRenderer.srcObject != null) ...[
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 1.0,
                  child: RTCVideoView(
                    call.remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
          ],

          // Glassmorphism Overlay (behind controls, above video)
          if (!call.isVideo || !isCallActive)
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(color: theme.colorScheme.surface.withValues(alpha: 0.5)),
              ),
            ),

          // Main Content (controls, header, visualizer)
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 40),
                _buildHeader(call),
                const Spacer(),
                if (!call.isVideo || !isCallActive) _buildVisualizer(call),
                const Spacer(),
                _buildControls(call),
                const SizedBox(height: 40),
              ],
            ),
          ),

          // Local Video PiP
          if (call.isVideo && isCallActive && !call.isCameraOff)
            Positioned(
              top: 40,
              right: 20,
              width: 100,
              height: 150,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  color: Colors.black38,
                  child: RTCVideoView(call.localRenderer, mirror: true),
                ),
              ),
            ),

          // TALK-WHILE-MUTED ALERT
          if (call.isTalkingWhileMuted)
            Positioned(
              top: 150,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(color: theme.colorScheme.error.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.mic_off_rounded, color: theme.colorScheme.onError, size: 20),
                      const SizedBox(width: 8),
                      Text("You are muted", style: TextStyle(color: theme.colorScheme.onError, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(CallProvider call) {
    String statusText = 'Connecting...';
    if (call.state == CallState.incoming) {
      statusText = call.isAccepted ? 'Connecting...' : 'Incoming Call';
    }
    if (call.state == CallState.outgoing) {
      statusText = call.isRinging ? 'Ringing...' : 'Calling...';
    }
    if (call.state == CallState.active) {
      statusText = _formatDuration(_callDuration);
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (call.state == CallState.active) ...[
              _buildNetworkQualityIndicator(call),
              const SizedBox(width: 12),
            ],
            Flexible(
              child: Text(
                call.remoteJid?.split('@').first ?? 'Private Caller',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (call.state == CallState.active) ...[
              _buildConnectionQualityText(call),
              const SizedBox(width: 8),
              Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              statusText,
              style: TextStyle(
                color: call.state == CallState.active
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.primary,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNetworkQualityIndicator(CallProvider call) {
    final hasRemoteStream = call.remoteRenderer.srcObject != null;
    final hasAudioTrack = hasRemoteStream && call.remoteRenderer.srcObject!.getAudioTracks().isNotEmpty;
    int bars;
    Color color;
    String qualityText;

    if (hasAudioTrack) {
      bars = 4;
      color = Colors.green;
      qualityText = 'Connected';
    } else if (hasRemoteStream) {
      bars = 2;
      color = Colors.orange;
      qualityText = 'No Audio';
    } else {
      bars = 1;
      color = Theme.of(context).colorScheme.error;
      qualityText = 'Connecting';
    }

    return Tooltip(
      message: 'Connection: $qualityText',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(4, (index) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 1),
            width: 4,
            height: 6 + (index * 3).toDouble(),
            decoration: BoxDecoration(
              color: index < bars ? color : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(2),
              boxShadow: index < bars ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4)] : null,
            ),
          );
        }),
      ),
    );
  }

  Widget _buildConnectionQualityText(CallProvider call) {
    final hasRemoteStream = call.remoteRenderer.srcObject != null;
    final hasAudioTrack = hasRemoteStream && call.remoteRenderer.srcObject!.getAudioTracks().isNotEmpty;
    String qualityText;
    Color qualityColor;

    if (hasAudioTrack) {
      qualityText = call.isVideo ? 'Video' : 'Voice';
      qualityColor = Colors.green;
    } else if (hasRemoteStream) {
      qualityText = 'No Audio';
      qualityColor = Colors.orange;
    } else {
      qualityText = 'Waiting';
      qualityColor = Theme.of(context).colorScheme.error;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: qualityColor.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: qualityColor.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        qualityText.toUpperCase(),
        style: TextStyle(color: qualityColor, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.0),
      ),
    );
  }

  Widget _buildVisualizer(CallProvider call) {
    final theme = Theme.of(context);
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Pulse rings for incoming/outgoing
          if (call.state != CallState.active)
            ...List.generate(3, (index) {
              return AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  double value = (_pulseController.value + (index * 0.33)) % 1.0;
                  return Container(
                    width: 260 * value,
                    height: 260 * value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5 * (1 - value)),
                        width: 2,
                      ),
                    ),
                  );
                },
              );
            }),

          // DUAL Neon Visualizer Rings (Active Call)
          if (call.state == CallState.active) ...[
            // REMOTE WAVE
            CustomPaint(
              painter: WaveformPainter(
                _waveController,
                true,
                context: context,
                volume: call.remoteVolume,
                color: Theme.of(context).colorScheme.secondary,
                radius: 105,
                isGlow: true,
              ),
              child: const SizedBox(width: 200, height: 200),
            ),
            // LOCAL WAVE
            CustomPaint(
              painter: WaveformPainter(
                _waveController,
                true,
                context: context,
                volume: call.localVolume,
                color: Theme.of(context).colorScheme.primary,
                radius: 85,
                isLocal: true,
                isGlow: true,
              ),
              child: const SizedBox(width: 200, height: 200),
            ),
          ],

          // Avatar or Core Circle
          Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
              boxShadow: [
                BoxShadow(
                  color: (call.isMicMuted ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary).withValues(alpha: 0.2),
                  blurRadius: 40,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: Center(
              child: call.isMicMuted
                  ? Icon(Icons.mic_off_rounded, color: Theme.of(context).colorScheme.error, size: 48)
                  : Icon(Icons.person_rounded, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5), size: 64),
            ),
          ),

          // DTMF KEYPAD OVERLAY
          if (_showDtmfPad && isCallActive)
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  color: theme.colorScheme.surface.withValues(alpha: 0.9),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      Text(
                        'DTMF Keypad',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 40),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 48),
                        child: _buildDtmfGrid(call),
                      ),
                      const SizedBox(height: 40),
                      _enhancedCircleButton(
                        icon: Icons.close_rounded,
                        label: 'Hide',
                        isActive: true,
                        activeColor: theme.colorScheme.outline,
                        onPressed: () => setState(() => _showDtmfPad = false),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControls(CallProvider call) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          // Primary controls row
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 20,
            runSpacing: 20,
            children: [
              _enhancedCircleButton(
                icon: call.isMicMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                label: call.isMicMuted ? 'Unmute' : 'Mute',
                isActive: !call.isMicMuted,
                activeColor: Theme.of(context).colorScheme.error,
                onPressed: () {
                  HapticFeedback.lightImpact();
                  call.toggleMute();
                },
              ),
              _enhancedCircleButton(
                icon: call.isSpeakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                label: call.isSpeakerOn ? 'Speaker On' : 'Speaker Off',
                isActive: call.isSpeakerOn,
                activeColor: Theme.of(context).colorScheme.primary,
                onPressed: () {
                  HapticFeedback.lightImpact();
                  call.toggleSpeaker();
                },
              ),
              if (isCallActive)
                _enhancedCircleButton(
                  icon: Icons.dialpad_rounded,
                  label: 'Keypad',
                  isActive: _showDtmfPad,
                  activeColor: theme.colorScheme.primary,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(() => _showDtmfPad = !_showDtmfPad);
                  },
                ),
              if (call.state == CallState.active)
                _enhancedCircleButton(
                  icon: Icons.fiber_manual_record_rounded,
                  label: call.isRecording ? 'Stop Rec' : 'Record',
                  isActive: call.isRecording,
                  activeColor: Theme.of(context).colorScheme.error,
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    call.toggleRecording();
                  },
                ),
              if (call.isVideo)
                _enhancedCircleButton(
                  icon: call.isCameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
                  label: call.isCameraOff ? 'Camera On' : 'Camera Off',
                  isActive: !call.isCameraOff,
                  activeColor: Theme.of(context).colorScheme.secondary,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    call.toggleCamera();
                  },
                ),
              if (call.isVideo && !call.isCameraOff)
                _enhancedCircleButton(
                  icon: Icons.flip_camera_ios_rounded,
                  label: 'Switch',
                  isActive: true,
                  activeColor: Theme.of(context).colorScheme.secondary,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    call.switchCamera();
                  },
                ),
            ],
          ),
          const SizedBox(height: 56),
          // End call button
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (call.state == CallState.incoming) ...[
                _enhancedActionButton(
                  icon: Icons.call_rounded,
                  color: Colors.greenAccent,
                  label: 'Accept',
                  onPressed: () {
                    HapticFeedback.heavyImpact();
                    call.acceptCall();
                  },
                ),
                const SizedBox(width: 32),
              ],
              _endCallButton(
                onPressed: () {
                  HapticFeedback.heavyImpact();
                  if (call.state == CallState.incoming) {
                    call.declineCall();
                  } else {
                    call.endCall();
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _enhancedCircleButton({
    required IconData icon,
    required String label,
    required bool isActive,
    Color? activeColor,
    required VoidCallback onPressed,
  }) {
    final color = activeColor ?? Theme.of(context).colorScheme.onSurface;
    final isOff = !isActive;

    return Column(
      children: [
        GestureDetector(
          onTap: onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: isOff ? Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3) : color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
              border: Border.all(
                color: isOff ? Theme.of(context).colorScheme.outline.withValues(alpha: 0.3) : color,
                width: 2,
              ),
              boxShadow: isActive
                  ? [
                      BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 12, spreadRadius: 2),
                    ]
                  : null,
            ),
            child: Icon(icon, color: isOff ? Theme.of(context).colorScheme.onSurfaceVariant : color, size: 28),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: TextStyle(
            color: isActive ? Theme.of(context).colorScheme.onSurface : Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 11,
            fontWeight: isActive ? FontWeight.w900 : FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _endCallButton({required VoidCallback onPressed}) {
    final errorColor = Theme.of(context).colorScheme.error;
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: errorColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: errorColor.withValues(alpha: 0.5), blurRadius: 20, spreadRadius: 2),
          ],
        ),
        child: Icon(Icons.call_end_rounded, color: Theme.of(context).colorScheme.onError, size: 32),
      ),
    );
  }

  Widget _enhancedActionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Column(
      children: [
        GestureDetector(
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 12, spreadRadius: 2),
              ],
            ),
            child: Icon(icon, color: Colors.black, size: 32),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return d.inHours > 0 ? '${twoDigits(d.inHours)}:$minutes:$seconds' : '$minutes:$seconds';
  }

  Widget _buildDtmfGrid(CallProvider call) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 3,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      childAspectRatio: 1.0,
      children: [
        '1', '2', '3',
        '4', '5', '6',
        '7', '8', '9',
        '*', '0', '#',
      ].map((tone) => _dtmfButton(tone, call)).toList(),
    );
  }

  Widget _dtmfButton(String tone, CallProvider call) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          call.sendDtmf(tone);
        },
        customBorder: const CircleBorder(),
        child: Center(
          child: Text(
            tone,
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class WaveformPainter extends CustomPainter {
  final Animation<double> animation;
  final bool isActive;
  final BuildContext context;
  final double volume;
  final Color? color;
  final double radius;
  final bool isLocal;
  final bool isGlow;

  WaveformPainter(
    this.animation,
    this.isActive, {
    required this.context,
    required this.volume,
    this.color,
    this.radius = 60,
    this.isLocal = false,
    this.isGlow = false,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    if (!isActive) return;

    final baseColor = color ?? Theme.of(context).colorScheme.primary;

    final paint = Paint()
      ..color = baseColor.withValues(alpha: 0.9)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    if (isGlow) {
      paint.maskFilter = const MaskFilter.blur(BlurStyle.solid, 4);
    }

    final double centerX = size.width / 2;
    final double centerY = size.height / 2;
    final int barCount = isLocal ? 32 : 48;
    final double angleStep = (2 * math.pi) / barCount;

    final level = volume;

    for (int i = 0; i < barCount; i++) {
      double angle = (i * angleStep) + (isLocal ? animation.value * 0.2 : -animation.value * 0.1);

      double barHeight = 3 + (level * 45 * (0.8 + 0.2 * math.sin(animation.value * math.pi + i)));

      double innerRadius = radius;
      double outerRadius = radius + barHeight;

      canvas.drawLine(
        Offset(centerX + innerRadius * math.cos(angle), centerY + innerRadius * math.sin(angle)),
        Offset(centerX + outerRadius * math.cos(angle), centerY + outerRadius * math.sin(angle)),
        paint,
      );

      if (isGlow && level > 0.1) {
        final glowPaint = Paint()
          ..color = baseColor.withValues(alpha: 0.3)
          ..strokeWidth = 6
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

        canvas.drawLine(
          Offset(centerX + innerRadius * math.cos(angle), centerY + innerRadius * math.sin(angle)),
          Offset(centerX + outerRadius * math.cos(angle), centerY + outerRadius * math.sin(angle)),
          glowPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) => true;
}
