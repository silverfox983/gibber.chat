import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import '../models/story_models.dart';
import '../providers/chat_provider.dart';
import '../services/story_service.dart';
import '../services/avatar_cache_service.dart';
import 'story_viewer.dart';

class StoryRow extends StatefulWidget {
  final StoryService storyService;
  final List<String> contactJids;

  const StoryRow({
    super.key,
    required this.storyService,
    required this.contactJids,
  });

  @override
  State<StoryRow> createState() => _StoryRowState();
}

class _StoryRowState extends State<StoryRow> {
  List<Story> _myStories = [];
  Map<String, List<Story>> _contactStories = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStories();
  }

  Future<void> _loadStories() async {
    setState(() => _loading = true);
    try {
      final myStories = await widget.storyService.fetchMyStories();
      final contactStories = <String, List<Story>>{};
      for (final jid in widget.contactJids) {
        final stories = await widget.storyService.fetchContactStories(jid);
        if (stories.isNotEmpty) {
          contactStories[jid] = stories;
        }
      }
      if (mounted) {
        setState(() {
          _myStories = myStories;
          _contactStories = contactStories;
          _loading = false;
        });

        // Push story state to ChatProvider for conversation list rings
        final chatProvider = context.read<ChatProvider>();
        for (final jid in widget.contactJids) {
          final stories = contactStories[jid];
          if (stories != null && stories.isNotEmpty) {
            final hasUnviewed = stories.any((s) => !s.viewed);
            chatProvider.updateStoryState(jid, hasStory: true, hasUnviewed: hasUnviewed);
          } else {
            chatProvider.updateStoryState(jid, hasStory: false, hasUnviewed: false);
          }
        }
        // Mark own story state
        chatProvider.updateStoryState(widget.storyService.accountJid,
            hasStory: myStories.isNotEmpty,
            hasUnviewed: myStories.any((s) => !s.viewed));
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openMyStories() {
    if (_myStories.isEmpty) {
      _showAddStorySheet();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => StoryViewer(
          stories: _myStories,
          startIndex: 0,
          authorJid: widget.storyService.accountJid,
          onViewed: (id) => widget.storyService.markViewed(id),
        ),
      ),
    );
  }

  void _openContactStories(String contactJid) {
    final stories = _contactStories[contactJid];
    if (stories == null || stories.isEmpty) return;
    final startIndex = stories.indexWhere((s) => !s.viewed);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => StoryViewer(
          stories: stories,
          startIndex: startIndex >= 0 ? startIndex : 0,
          authorJid: contactJid,
          onViewed: (id) => widget.storyService.markViewed(id),
        ),
      ),
    );
  }

  Future<void> _showAddStorySheet() async {
    final picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (image == null || !mounted) return;

    final file = File(image.path);
    final caption = await _showCaptionDialog();
    if (!mounted) return;

    final story = await widget.storyService.publishStory(file, caption: caption);
    if (story != null && mounted) {
      setState(() {
        _myStories.insert(0, story);
      });
    }
  }

  Future<String?> _showCaptionDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a caption'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Write a caption...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Share'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 90,
        child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    final hasAnyStories = _myStories.isNotEmpty || _contactStories.isNotEmpty;
    if (!hasAnyStories) return const SizedBox.shrink();

    return SizedBox(
      height: 90,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: 1 + _contactStories.length,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildMyStoryRing();
          }
          final contactJid = _contactStories.keys.elementAt(index - 1);
          final stories = _contactStories[contactJid]!;
          final hasUnviewed = stories.any((s) => !s.viewed);
          return _buildContactRing(contactJid, hasUnviewed);
        },
      ),
    );
  }

  Widget _buildMyStoryRing() {
    final hasUnviewed = _myStories.any((s) => !s.viewed);
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Column(
        children: [
          _StoryAvatar(
            label: 'Your Story',
            hasUnviewed: hasUnviewed,
            isOwn: true,
            onTap: _openMyStories,
          ),
          const SizedBox(height: 4),
          const Text('Your Story', style: TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildContactRing(String jid, bool hasUnviewed) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Column(
        children: [
          _StoryAvatar(
            label: jid,
            hasUnviewed: hasUnviewed,
            onTap: () => _openContactStories(jid),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 60,
            child: Text(
              jid.contains('@') ? jid.split('@')[0] : jid,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _StoryAvatar extends StatelessWidget {
  final String label;
  final bool hasUnviewed;
  final bool isOwn;
  final VoidCallback? onTap;

  const _StoryAvatar({
    required this.label,
    this.hasUnviewed = false,
    this.isOwn = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatarSize = 56.0;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: avatarSize + 6,
        height: avatarSize + 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isOwn
              ? LinearGradient(
                  colors: [
                    Theme.of(context).colorScheme.primary,
                    Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
                  ],
                )
              : hasUnviewed
                  ? LinearGradient(
                      colors: [
                        Theme.of(context).colorScheme.primary,
                        Colors.purpleAccent,
                      ],
                    )
                  : null,
          border: !isOwn && !hasUnviewed
              ? Border.all(color: Colors.grey.shade400, width: 2)
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: FutureBuilder<Uint8List?>(
            future: AvatarCacheService().getAvatar(label),
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes != null) {
                return CircleAvatar(
                  radius: avatarSize / 2,
                  backgroundImage: MemoryImage(bytes),
                );
              }
              return CircleAvatar(
                radius: avatarSize / 2,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  label.isNotEmpty ? label[0].toUpperCase() : '?',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: avatarSize / 2.5,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
