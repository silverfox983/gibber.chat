import 'package:flutter/material.dart';
import '../services/transcription_service.dart';

class LiveCaptionsPanel extends StatefulWidget {
  final TranscriptionService transcriptionService;
  final bool isExpanded;
  final VoidCallback? onToggleExpand;

  const LiveCaptionsPanel({
    super.key,
    required this.transcriptionService,
    this.isExpanded = true,
    this.onToggleExpand,
  });

  @override
  State<LiveCaptionsPanel> createState() => _LiveCaptionsPanelState();
}

class _LiveCaptionsPanelState extends State<LiveCaptionsPanel> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.transcriptionService.addListener(_onTranscriptUpdate);
  }

  @override
  void dispose() {
    widget.transcriptionService.removeListener(_onTranscriptUpdate);
    _scrollController.dispose();
    super.dispose();
  }

  void _onTranscriptUpdate() {
    if (!mounted) return;
    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.transcriptionService;
    final segments = service.segments;
    final isListening = service.status == TranscriptionStatus.listening;

    if (!widget.isExpanded) {
      return _buildCollapsed(context, service);
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: Border.all(
          color: isListening
              ? Colors.cyan.withValues(alpha: 0.5)
              : Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
          width: isListening ? 1.5 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(context, service),
          const Divider(height: 1),
          _buildTranscriptArea(context, segments),
          if (service.partialText.isNotEmpty) _buildPartialText(context, service),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, TranscriptionService service) {
    final isLoading = service.status == TranscriptionStatus.loading;
    final loadProgress = service.modelLoadProgress;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isLoading
                    ? Icons.hourglass_empty
                    : service.status == TranscriptionStatus.listening
                        ? Icons.record_voice_over
                        : Icons.subtitles,
                size: 18,
                color: service.status == TranscriptionStatus.listening
                    ? Colors.cyan
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _getStatusText(service),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: service.status == TranscriptionStatus.listening
                        ? Colors.cyan
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (isLoading && loadProgress > 0)
                Text(
                  '${(loadProgress * 100).toInt()}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              if (service.status == TranscriptionStatus.listening)
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onToggleExpand,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          if (isLoading && loadProgress > 0) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: loadProgress,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
              minHeight: 3,
            ),
          ],
        ],
      ),
    );
  }

  String _getStatusText(TranscriptionService service) {
    switch (service.status) {
      case TranscriptionStatus.idle:
        return 'Transcription Off';
      case TranscriptionStatus.loading:
        return 'Loading Whisper Model...';
      case TranscriptionStatus.ready:
        return 'Transcription Ready';
      case TranscriptionStatus.listening:
        return 'Live Transcription';
      case TranscriptionStatus.paused:
        return 'Transcription Paused';
      case TranscriptionStatus.error:
        return 'Error: ${service.error}';
    }
  }

  Widget _buildTranscriptArea(BuildContext context, List<TranscriptSegment> segments) {
    if (segments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Waiting for speech...',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
            fontSize: 13,
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 150),
      child: ListView.builder(
        controller: _scrollController,
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: segments.length,
        itemBuilder: (context, index) {
          final segment = segments[index];
          final isLocal = segment.speaker == 'local';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${segment.timestamp.inMinutes}:${(segment.timestamp.inSeconds % 60).toString().padLeft(2, '0')}',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 3,
                  height: 14,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: isLocal ? Colors.cyan : Colors.orangeAccent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    segment.text,
                    style: TextStyle(
                      fontSize: 13,
                      color: isLocal
                          ? Colors.cyan.shade100
                          : Colors.orange.shade100,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPartialText(BuildContext context, TranscriptionService service) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(
        service.partialText,
        style: TextStyle(
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildCollapsed(BuildContext context, TranscriptionService service) {
    if (service.status != TranscriptionStatus.listening) {
      return const SizedBox.shrink();
    }

    final lastSegment =
        service.segments.isNotEmpty ? service.segments.last : null;
    final displayText = service.partialText.isNotEmpty
        ? service.partialText
        : lastSegment?.text ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              displayText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.expand, size: 16, color: Colors.white70),
            onPressed: widget.onToggleExpand,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ],
      ),
    );
  }
}