import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import 'dart:math' as math;
import '../providers/call_provider.dart';
import '../models/group_call_models.dart';
import '../services/transcription_service.dart';
import '../services/assistant_service.dart';
import '../widgets/live_captions_panel.dart';

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
  bool _showCaptions = false;
  bool _showAssistant = false;
  bool _showParticipants = false;
  final TextEditingController _assistantController = TextEditingController();
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
      if (_showCaptions) {
        final ts = Provider.of<TranscriptionService>(context, listen: false);
        if (ts.status == TranscriptionStatus.listening || ts.status == TranscriptionStatus.paused) {
          ts.stopTranscription();
        }
        _showCaptions = false;
      }
      if (_showAssistant) {
        final as2 = Provider.of<AssistantService>(context, listen: false);
        as2.clearMessages();
        _showAssistant = false;
      }
      final error = _callProvider.lastError;
      if (error != null && error.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
        );
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) Navigator.of(context).maybePop();
        });
      } else {
        Navigator.of(context).maybePop();
      }
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
    _assistantController.dispose();
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
                  color: theme.colorScheme.surface,
                ),
              ),
            ),

          // CRITICAL: RTCVideoView - ALWAYS on top when stream exists
          if (call.isGroupCall) ...[
            Positioned.fill(
              child: _buildGroupVideoGrid(call),
            ),
          ] else if (call.remoteRenderer.srcObject != null) ...[
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
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        const SizedBox(height: 20),
                        _buildHeader(call),
                        const Spacer(),
                        if (!call.isVideo || !isCallActive) _buildVisualizer(call),
                        if (_showCaptions)
                          Consumer<TranscriptionService>(
                            builder: (context, ts, _) => LiveCaptionsPanel(
                              transcriptionService: ts,
                              isExpanded: true,
                              onToggleExpand: () => setState(() => _showCaptions = false),
                            ),
                          ),
                        if (!_showCaptions)
                          Consumer<TranscriptionService>(
                            builder: (context, ts, _) => LiveCaptionsPanel(
                              transcriptionService: ts,
                              isExpanded: false,
                              onToggleExpand: () => setState(() => _showCaptions = true),
                            ),
                          ),
                        if (_showAssistant)
                          Consumer<AssistantService>(
                            builder: (context, as, _) => _buildAssistantPanel(as),
                          ),
                        const Spacer(),
                        _buildControls(call),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Local Video PiP (Only for 1-on-1 calls)
          if (!call.isGroupCall && call.isVideo && isCallActive && !call.isCameraOff)
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

          // GROUP CALL PARTICIPANTS PANEL
          if (call.isGroupCall && _showParticipants)
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              child: _buildParticipantsPanel(call),
            ),
        ],
      ),
    );
  }

  Widget _buildGroupVideoGrid(CallProvider call) {
    final session = call.groupCallSession;
    final renderers = call.groupRenderers;
    final participants = session?.participants ?? {};
    final showLocal = call.isVideo && !call.isCameraOff;
    final totalCount = renderers.length + (showLocal ? 1 : 0);

    if (totalCount == 0) {
      return Container(
        color: Theme.of(context).colorScheme.surface,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.people_outline_rounded, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                'Waiting for participants...',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (session != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${session.participantCount + 1} in call',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    int crossAxisCount = 1;
    if (totalCount > 6) {
      crossAxisCount = 3;
    } else if (totalCount > 2) {
      crossAxisCount = 2;
    }

    final children = <Widget>[];

    if (showLocal) {
      children.add(_buildGridTile(
        renderer: call.localRenderer,
        name: 'You',
        mirror: true,
        isMuted: call.isMicMuted,
      ));
    }

    for (final entry in renderers.entries) {
      final peerId = entry.key;
      final renderer = entry.value;
      final participant = participants[peerId];
      final name = participant?.displayName ?? peerId.split('@').first.split('/').last;
      final isMuted = participant != null && !participant.audioEnabled;
      children.add(_buildGridTile(
        renderer: renderer,
        name: name,
        mirror: false,
        isMuted: isMuted,
        isSpeaking: call.groupAudioLevels[peerId] != null && (call.groupAudioLevels[peerId] ?? 0) > 0.3,
      ));
    }

    return Padding(
      padding: const EdgeInsets.only(top: 80, bottom: 200, left: 16, right: 16),
      child: GridView.count(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.75,
        children: children,
      ),
    );
  }

  Widget _buildGridTile({
    required RTCVideoRenderer renderer,
    required String name,
    required bool mirror,
    bool isMuted = false,
    bool isSpeaking = false,
  }) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          border: isSpeaking
              ? Border.all(color: theme.colorScheme.primary, width: 3)
              : null,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: RTCVideoView(
                renderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: mirror,
              ),
            ),
            Positioned(
              bottom: 8,
              left: 8,
              right: 8,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    color: theme.colorScheme.surface.withValues(alpha: 0.5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isMuted) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.mic_off_rounded, size: 14, color: theme.colorScheme.error),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParticipantsPanel(CallProvider call) {
    final theme = Theme.of(context);
    final session = call.groupCallSession;
    final participants = session?.participants ?? <String, JanusParticipant>{};
    final myName = call.groupCallSession?.displayName ?? 'You';

    return ClipRRect(
      borderRadius: const BorderRadius.only(topLeft: Radius.circular(20), bottomLeft: Radius.circular(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          color: theme.colorScheme.surface.withValues(alpha: 0.85),
          width: 280,
          child: Column(
            children: [
              const SizedBox(height: 60),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Participants (${participants.length + 1})',
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close_rounded, color: theme.colorScheme.onSurfaceVariant, size: 20),
                      onPressed: () => setState(() => _showParticipants = false),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ],
                ),
              ),
              Divider(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2), height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    ListTile(
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.2),
                        child: Text(myName[0].toUpperCase(), style: TextStyle(color: theme.colorScheme.primary, fontSize: 14, fontWeight: FontWeight.w800)),
                      ),
                      title: Text('$myName (You)', style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.w700)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(call.isMicMuted ? Icons.mic_off_rounded : Icons.mic_rounded, size: 16, color: call.isMicMuted ? theme.colorScheme.error : theme.colorScheme.primary),
                          if (call.isVideo && !call.isCameraOff) ...[
                            const SizedBox(width: 8),
                            Icon(Icons.videocam_rounded, size: 16, color: theme.colorScheme.primary),
                          ],
                        ],
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      dense: true,
                    ),
                    ...participants.entries.map((entry) {
                      final p = entry.value;
                      final participantId = entry.key;
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: theme.colorScheme.secondary.withValues(alpha: 0.2),
                          child: Text(p.displayName[0].toUpperCase(), style: TextStyle(color: theme.colorScheme.secondary, fontSize: 14, fontWeight: FontWeight.w800)),
                        ),
                        title: Text(p.displayName, style: TextStyle(color: theme.colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.w700)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!p.audioEnabled) Icon(Icons.mic_off_rounded, size: 16, color: theme.colorScheme.error),
                            if (!p.videoEnabled) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.videocam_off_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                            ],
                            PopupMenuButton<String>(
                              icon: Icon(Icons.more_vert, size: 16, color: theme.colorScheme.onSurfaceVariant),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                              onSelected: (value) {
                                if (value == 'mute') {
                                  call.muteParticipant(participantId, !p.audioEnabled);
                                } else if (value == 'kick') {
                                  _showKickParticipantDialog(call, participantId, p.displayName);
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'mute',
                                  child: Row(
                                    children: [
                                      Icon(p.audioEnabled ? Icons.mic_off : Icons.mic, size: 18),
                                      const SizedBox(width: 8),
                                      Text(p.audioEnabled ? 'Mute' : 'Unmute'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'kick',
                                  child: Row(
                                    children: [
                                      Icon(Icons.person_remove, size: 18, color: theme.colorScheme.error),
                                      const SizedBox(width: 8),
                                      Text('Remove', style: TextStyle(color: theme.colorScheme.error)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                        dense: true,
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),
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
    if (call.state == CallState.idle) {
      statusText = 'Call Ended';
    }

    final showOutgoingCountdown = call.state == CallState.outgoing && !call.isRinging;
    final countdown = showOutgoingCountdown ? call.outgoingCallSeconds : 0;

    final displayName = call.isGroupCall
        ? (call.groupCallSession?.roomJid.split('@').first ?? 'Group Call')
        : (call.remoteJid?.split('@').first
            ?? call.lastDisplayName?.split('@').first
            ?? 'Private Caller');
    final participantCount = call.isGroupCall && call.groupCallSession != null
        ? call.groupCallSession!.participantCount + 1
        : null;

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
                displayName,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: call.isGroupCall ? 22 : 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (call.isGroupCall && participantCount != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.people_rounded, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                '$participantCount ${participantCount == 1 ? "participant" : "participants"}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        const SizedBox(height: 4),
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
              _buildCallQualityStats(call),
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
            if (showOutgoingCountdown) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.error.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  '${countdown}s',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
            if (call.state == CallState.active && !call.isGroupCall) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.call_merge_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
                tooltip: 'Transfer Call',
                onPressed: () => _showTransferDialog(call),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ],
        ),
        if (call.lastError != null && call.state != CallState.active) ...[
          const SizedBox(height: 4),
          Text(
            call.lastError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
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

  Widget _buildCallQualityStats(CallProvider call) {
    final stats = call.qualityStats;
    if (stats == null) return const SizedBox.shrink();

    String rttText = '${(stats.roundTripTime * 1000).toInt()}ms';
    String bitrateText = stats.bitrate > 0 ? '${(stats.bitrate / 1000).toInt()}kbps' : '';

    return GestureDetector(
      onTap: () => _showQualityStatsDialog(call),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.signal_cellular_alt_rounded, size: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 2),
          Text(
            rttText,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (bitrateText.isNotEmpty) ...[
            const SizedBox(width: 4),
            Icon(Icons.speed_rounded, size: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 2),
            Text(
              bitrateText,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showQualityStatsDialog(CallProvider call) {
    final stats = call.qualityStats;
    if (stats == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Call Quality'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statRow('RTT', '${(stats.roundTripTime * 1000).toInt()} ms'),
            _statRow('Bitrate', stats.bitrate > 0 ? '${(stats.bitrate / 1000).toInt()} kbps' : 'N/A'),
            _statRow('Jitter', '${stats.jitter} ms'),
            _statRow('Packet Loss', '${stats.packetLoss.toStringAsFixed(1)}%'),
            _statRow('Candidate Type', stats.candidateType),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _statRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
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
              if (call.state == CallState.active && !call.isGroupCall)
                _enhancedCircleButton(
                  icon: call.isOnHold ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  label: call.isOnHold ? 'Resume' : 'Hold',
                  isActive: call.isOnHold,
                  activeColor: call.isOnHold ? Colors.orange : Theme.of(context).colorScheme.secondary,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    call.toggleHold();
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
                  icon: Icons.person_add_rounded,
                  label: 'Add',
                  isActive: true,
                  activeColor: theme.colorScheme.primary,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    _showAddParticipantDialog(call);
                  },
                ),
              if (call.isGroupCall && call.state == CallState.active)
                _enhancedCircleButton(
                  icon: Icons.people_rounded,
                  label: '${(call.groupCallSession?.participantCount ?? 0) + 1}',
                  isActive: _showParticipants,
                  activeColor: Colors.teal,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(() => _showParticipants = !_showParticipants);
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
                  activeColor: theme.colorScheme.secondary,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    call.switchCamera();
                  },
                ),
              if (call.state == CallState.active)
                _enhancedCircleButton(
                  icon: _showCaptions ? Icons.subtitles : Icons.subtitles_outlined,
                  label: 'Captions',
                  isActive: _showCaptions,
                  activeColor: Colors.cyan,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(() => _showCaptions = !_showCaptions);
                    final ts = Provider.of<TranscriptionService>(context, listen: false);
                    if (_showCaptions) {
                      if (ts.status == TranscriptionStatus.idle) {
                        ts.initialize().then((_) {
                          ts.startTranscription(call.localRenderer.srcObject, call.remoteRenderer.srcObject);
                        });
                      } else if (ts.status == TranscriptionStatus.ready) {
                        ts.startTranscription(call.localRenderer.srcObject, call.remoteRenderer.srcObject);
                      }
                    } else {
                      if (ts.status == TranscriptionStatus.listening) {
                        ts.stopTranscription();
                      }
                    }
                  },
                ),
                if (call.state == CallState.active)
                _enhancedCircleButton(
                  icon: Icons.auto_awesome_rounded,
                  label: 'AI',
                  isActive: _showAssistant,
                  activeColor: Colors.purpleAccent,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(() => _showAssistant = !_showAssistant);
                    if (_showAssistant) {
                      final as2 = Provider.of<AssistantService>(context, listen: false);
                      if (as2.status == AssistantStatus.idle) {
                        as2.initialize();
                      }
                    }
                  },
                ),
              if (call.state == CallState.active && call.isVideo && !call.isGroupCall)
                _enhancedCircleButton(
                  icon: call.isScreenSharing ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded,
                  label: call.isScreenSharing ? 'Stop Share' : 'Share Screen',
                  isActive: call.isScreenSharing,
                  activeColor: call.isScreenSharing ? Colors.orange : Theme.of(context).colorScheme.primary,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    call.toggleScreenShare();
                  },
                ),
            ],
          ),
          const SizedBox(height: 32),
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

  void _showAddParticipantDialog(CallProvider call) {
    final jidController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Participant', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter the JID of the person you want to invite to this call:'),
            const SizedBox(height: 16),
            TextField(
              controller: jidController,
              decoration: const InputDecoration(
                labelText: 'Contact JID',
                hintText: 'user@example.com',
                prefixIcon: Icon(Icons.person_rounded),
              ),
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () {
              final jid = jidController.text.trim();
              if (jid.isNotEmpty) {
                call.inviteParticipant(jid);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Invited $jid to the call')),
                );
              }
            },
            child: const Text('INVITE'),
          ),
        ],
      ),
    );
  }

  void _showTransferDialog(CallProvider call) {
    final jidController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Transfer Call', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter the number or JID to transfer the call to:'),
            const SizedBox(height: 16),
            TextField(
              controller: jidController,
              decoration: const InputDecoration(
                labelText: 'Transfer to',
                hintText: 'number@example.com',
                prefixIcon: Icon(Icons.call_merge_rounded),
              ),
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () {
              final target = jidController.text.trim();
              if (target.isNotEmpty) {
                call.transferCall(target);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Call transfer to $target')),
                );
              }
            },
            child: const Text('TRANSFER'),
          ),
        ],
      ),
    );
  }

  void _showKickParticipantDialog(CallProvider call, String participantId, String displayName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Participant', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text('Are you sure you want to remove $displayName from this call?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              call.kickParticipant(participantId);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Removed $displayName from the call')),
              );
            },
            child: const Text('REMOVE'),
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

  Widget _buildAssistantPanel(AssistantService assistant) {
    final theme = Theme.of(context);
    final isLoading = assistant.status == AssistantStatus.loading;
    final loadProgress = assistant.modelLoadProgress;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.auto_awesome_rounded, size: 16, color: Colors.purpleAccent),
            const SizedBox(width: 6),
            Text('Gibber AI', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            if (isLoading) ...[
              const SizedBox(width: 8),
              Text('(${assistant.modelLoadStatus})', style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
            ],
            const Spacer(),
            IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => setState(() => _showAssistant = false), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 24, minHeight: 24)),
          ]),
          if (isLoading && loadProgress > 0) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: loadProgress,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.purpleAccent),
              minHeight: 3,
            ),
          ],
          if (!isLoading) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              ActionChip(avatar: Icon(Icons.summarize_rounded, size: 14, color: Colors.purpleAccent), label: const Text('Summarize', style: TextStyle(fontSize: 11)), onPressed: () => _askAssistant('Summarize the call', assistant), backgroundColor: theme.colorScheme.surface, side: BorderSide(color: Colors.purpleAccent.withValues(alpha: 0.3))),
              ActionChip(avatar: Icon(Icons.checklist_rounded, size: 14, color: Colors.purpleAccent), label: const Text('Actions', style: TextStyle(fontSize: 11)), onPressed: () => _askAssistant('List action items', assistant), backgroundColor: theme.colorScheme.surface, side: BorderSide(color: Colors.purpleAccent.withValues(alpha: 0.3))),
              ActionChip(avatar: Icon(Icons.email_rounded, size: 14, color: Colors.purpleAccent), label: const Text('Follow Up', style: TextStyle(fontSize: 11)), onPressed: () => _askAssistant('Draft a follow-up', assistant), backgroundColor: theme.colorScheme.surface, side: BorderSide(color: Colors.purpleAccent.withValues(alpha: 0.3))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: _assistantController, style: const TextStyle(fontSize: 13), decoration: InputDecoration(hintText: 'Ask about the call...', hintStyle: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant), filled: true, fillColor: theme.colorScheme.surface, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none), isDense: true), onSubmitted: (v) => _askAssistant(v, assistant))),
              const SizedBox(width: 8),
              IconButton(icon: Icon(Icons.send_rounded, color: Colors.purpleAccent, size: 20), onPressed: () => _askAssistant(_assistantController.text, assistant), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
            ]),
            if (assistant.partialResponse.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.purpleAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_awesome_rounded, size: 12, color: Colors.purpleAccent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        assistant.partialResponse,
                        style: TextStyle(fontSize: 12, color: Colors.purpleAccent.shade100, fontStyle: FontStyle.italic),
                      ),
                    ),
                    const SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.purpleAccent)),
                  ],
                ),
              ),
            ],
            if (assistant.messages.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(constraints: const BoxConstraints(maxHeight: 100), child: ListView.builder(shrinkWrap: true, itemCount: assistant.messages.length, itemBuilder: (ctx, i) { final m = assistant.messages[i]; return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('${m.isUser ? "You" : "AI"}: ${m.text}', style: TextStyle(fontSize: 12, color: m.isUser ? Colors.purpleAccent.shade100 : Colors.cyan.shade100))); })),
            ],
            if (assistant.status == AssistantStatus.generating && assistant.partialResponse.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.purpleAccent)))),
          ],
        ],
      ),
    );
  }

  Future<void> _askAssistant(String query, AssistantService assistant) async {
    if (query.trim().isEmpty) return;
    _assistantController.clear();
    await assistant.ask(query);
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
