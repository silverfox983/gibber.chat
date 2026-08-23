import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../../providers/call_provider.dart';
import '../../screens/call_screen.dart';

class CallFloatingOverlay extends StatefulWidget {
  const CallFloatingOverlay({super.key});

  @override
  State<CallFloatingOverlay> createState() => _CallFloatingOverlayState();
}

class _CallFloatingOverlayState extends State<CallFloatingOverlay> {
  Offset _position = const Offset(20, 100);
  bool _isDragging = false;
  bool _isExpanded = false;

  static const double _collapsedWidth = 120;
  static const double _collapsedHeight = 160;

  @override
  Widget build(BuildContext context) {
    return Consumer<CallProvider>(
      builder: (context, call, _) {
        if (call.state == CallState.idle) return const SizedBox.shrink();

        if (_isExpanded) {
          return GestureDetector(
            onTap: () => setState(() => _isExpanded = false),
            child: Container(
              color: Colors.black54,
              child: const Center(
                child: Text('Tap to collapse',
                    style: TextStyle(color: Colors.white70)),
              ),
            ),
          );
        }

        return Positioned(
          right: _position.dx,
          top: _position.dy,
          child: GestureDetector(
            onPanStart: (_) => setState(() => _isDragging = true),
            onPanUpdate: (details) {
              setState(() {
                _position = Offset(
                  (_position.dx - details.delta.dx)
                      .clamp(0, MediaQuery.of(context).size.width - _collapsedWidth),
                  (_position.dy + details.delta.dy)
                      .clamp(0, MediaQuery.of(context).size.height - _collapsedHeight - 100),
                );
              });
            },
            onPanEnd: (_) => setState(() => _isDragging = false),
            onTap: () {
              context.pushNamed('call_screen');
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: _collapsedWidth,
              height: _collapsedHeight,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: _isDragging ? 0.4 : 0.2),
                    blurRadius: _isDragging ? 20 : 10,
                    spreadRadius: _isDragging ? 2 : 0,
                  ),
                ],
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: _buildCollapsedContent(call),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCollapsedContent(CallProvider call) {
    final isActive = call.state == CallState.active;
    final isIncoming = call.state == CallState.incoming;
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              _buildStateDot(call),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _getDisplayName(call),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: () => setState(() => _isExpanded = true),
                child: Icon(
                  Icons.open_in_full_rounded,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              if (call.isVideo && isActive && !call.isCameraOff && call.localRenderer.srcObject != null)
                Positioned.fill(
                  child: RTCVideoView(
                    call.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                )
              else
                Positioned.fill(
                  child: Container(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    child: Center(
                      child: Icon(
                        call.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                        size: 28,
                        color: theme.colorScheme.primary.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              Positioned(
                bottom: 4,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _miniButton(
                      icon: call.isMicMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      isActive: !call.isMicMuted,
                      onTap: () => call.toggleMute(),
                      size: 28,
                    ),
                    const SizedBox(width: 8),
                    _miniButton(
                      icon: Icons.call_end_rounded,
                      isActive: true,
                      activeColor: Colors.redAccent,
                      onTap: () {
                        if (isIncoming) {
                          call.declineCall();
                        } else {
                          call.endCall();
                        }
                      },
                      size: 28,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStateDot(CallProvider call) {
    Color color;
    if (call.state == CallState.active) {
      color = Colors.green;
    } else if (call.state == CallState.incoming) {
      color = Colors.orange;
    } else {
      color = Colors.blue;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4),
        ],
      ),
    );
  }

  String _getDisplayName(CallProvider call) {
    if (call.isGroupCall) {
      return call.groupCallSession?.roomJid.split('@').first ?? 'Group';
    }
    return call.remoteJid?.split('@').first ?? 'Call';
  }

  Widget _miniButton({
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
    Color? activeColor,
    required double size,
  }) {
    final color = isActive
        ? (activeColor ?? Theme.of(context).colorScheme.primary)
        : Theme.of(context).colorScheme.onSurfaceVariant;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(size * 0.25),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Icon(icon, size: size * 0.5, color: color),
      ),
    );
  }
}
