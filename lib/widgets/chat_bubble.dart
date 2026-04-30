import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/chat_models.dart';
import '../utils/color_generator.dart';

class ChatBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isGroup;
  final Widget content;
  final VoidCallback? onLongPress;
  final VoidCallback? onSwipe;
  final Widget? statusIcon;
  final bool hideSender;
  final bool hideTail;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isGroup,
    required this.content,
    this.statusIcon,
    this.onLongPress,
    this.onSwipe,
    this.hideSender = false,
    this.hideTail = false,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble> {
  double _dragOffset = 0.0;

  Color _getSenderColor(BuildContext context) {
    if (widget.message.senderColor == null) {
      return ColorGenerator.getColorForId(
        widget.message.senderId ?? 'Unknown',
      );
    }
    try {
      final hex = widget.message.senderColor!.replaceFirst('#', '0xFF');
      return Color(int.parse(hex));
    } catch (_) {
      return Theme.of(context).colorScheme.secondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.message.isSent;
    final bool showSender = !isMe && widget.isGroup && !widget.hideSender;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: widget.onLongPress,
        onHorizontalDragUpdate: (details) {
          if (widget.onSwipe != null) {
            setState(() {
              _dragOffset += details.delta.dx;
              if (_dragOffset > 0) _dragOffset = 0; // Only swipe left
              if (_dragOffset < -70) _dragOffset = -70; // Max drag
            });
          }
        },
        onHorizontalDragEnd: (details) {
          if (_dragOffset <= -60 && widget.onSwipe != null) {
            widget.onSwipe!();
          }
          setState(() {
            _dragOffset = 0;
          });
        },
        child: Transform.translate(
          offset: Offset(_dragOffset, 0),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (showSender && widget.message.senderName != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 4, top: 8),
                  child: Text(
                    widget.message.senderName!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                      color: _getSenderColor(context),
                    ),
                  ),
                ),
              ClipRRect(
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe || widget.hideTail ? 16 : 4),
                  bottomRight: Radius.circular(!isMe || widget.hideTail ? 16 : 4),
                ),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.85,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isMe
                          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                          : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(isMe || widget.hideTail ? 16 : 4),
                        bottomRight: Radius.circular(!isMe || widget.hideTail ? 16 : 4),
                      ),
                      border: Border.all(
                        color: isMe 
                            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
                            : Theme.of(context).colorScheme.secondary.withValues(alpha: 0.3),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        widget.content,
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              DateFormat('HH:mm').format(widget.message.timestamp),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: isMe 
                                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.7) 
                                    : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                              ),
                            ),
                            if (widget.message.isEdited) ...[
                              const SizedBox(width: 6),
                              Text(
                                'edited',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontStyle: FontStyle.italic,
                                  color: isMe ? Colors.white60 : Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                                ),
                              ),
                            ],
                            if (isMe) ...[
                              const SizedBox(width: 6),
                              widget.statusIcon ?? _buildStatusIcon(context),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(BuildContext context) {
    switch (widget.message.status) {
      case MessageStatus.sending:
        return const Icon(Icons.schedule_rounded, size: 11, color: Colors.white60);
      case MessageStatus.sent:
        return const Icon(Icons.done, size: 11, color: Colors.white70);
      case MessageStatus.delivered:
        return const Icon(Icons.done_all, size: 11, color: Colors.white70);
      case MessageStatus.read:
        return const Icon(Icons.done_all, size: 11, color: Colors.cyanAccent);
    }
  }
}