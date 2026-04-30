import 'package:flutter/material.dart';

class ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final VoidCallback onPickFile;
  final VoidCallback onPickGif;
  final VoidCallback onShowEmoji;
  final VoidCallback onVoice;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onPickImage,
    required this.onPickFile,
    required this.onPickGif,
    required this.onShowEmoji,
    required this.onVoice,
  });

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: const BoxDecoration(
        color: Colors.transparent,
      ),
      child: SafeArea(
        child: Row(
          children: [
            PopupMenuButton<String>(
              icon: Icon(
                Icons.add_circle_outline_rounded,
                color: Theme.of(context).colorScheme.primary,
                size: 26,
              ),
              onSelected: (val) {
                if (val == 'image') widget.onPickImage();
                if (val == 'file') widget.onPickFile();
                if (val == 'gif') widget.onPickGif();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'image',
                  child: Row(
                    children: [
                      Icon(Icons.image_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('Image'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'file',
                  child: Row(
                    children: [
                      Icon(Icons.insert_drive_file_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('File'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'gif',
                  child: Row(
                    children: [
                      Icon(Icons.gif_box_rounded, size: 20),
                      SizedBox(width: 12),
                      Text('GIF'),
                    ],
                  ),
                ),
              ],
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        maxLines: 4,
                        minLines: 1,
                        style: const TextStyle(
                          fontSize: 14,
                          fontFamily: 'monospace',
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Type a message...',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onSubmitted: (_) => widget.onSend(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            HoverScale(
              child: GestureDetector(
                onTap: () {
                  if (widget.controller.text.trim().isEmpty) {
                    widget.onVoice();
                  } else {
                    widget.onSend();
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      )
                    ],
                  ),
                  child: ListenableBuilder(
                    listenable: widget.controller,
                    builder: (context, _) {
                      final hasText = widget.controller.text.trim().isNotEmpty;
                      return Icon(
                        hasText ? Icons.send_rounded : Icons.mic_rounded,
                        color: Theme.of(context).colorScheme.onPrimary,
                        size: 18,
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HoverScale extends StatefulWidget {
  final Widget child;
  const HoverScale({super.key, required this.child});

  @override
  State<HoverScale> createState() => _HoverScaleState();
}

class _HoverScaleState extends State<HoverScale> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedScale(
        scale: _isHovered ? 1.1 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}
