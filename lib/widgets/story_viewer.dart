import 'dart:async';
import 'package:flutter/material.dart';
import '../models/story_models.dart';

class StoryViewer extends StatefulWidget {
  final List<Story> stories;
  final int startIndex;
  final String authorJid;
  final void Function(String storyId)? onViewed;
  final VoidCallback? onClose;

  const StoryViewer({
    super.key,
    required this.stories,
    this.startIndex = 0,
    required this.authorJid,
    this.onViewed,
    this.onClose,
  });

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> with TickerProviderStateMixin {
  late PageController _pageController;
  late int _currentIndex;
  Timer? _autoAdvance;
  late AnimationController _progressController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.startIndex;
    _pageController = PageController(initialPage: widget.startIndex);
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _progressController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _nextStory();
      }
    });
    _startTimer();
    _markCurrentViewed();
  }

  @override
  void dispose() {
    _autoAdvance?.cancel();
    _progressController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _startTimer() {
    _autoAdvance?.cancel();
    _progressController.reset();
    _progressController.forward();
  }

  void _markCurrentViewed() {
    final story = widget.stories[_currentIndex];
    widget.onViewed?.call(story.id);
  }

  void _nextStory() {
    if (_currentIndex < widget.stories.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onClose?.call();
      Navigator.of(context).pop();
    }
  }

  void _prevStory() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _startTimer();
    _markCurrentViewed();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            itemCount: widget.stories.length,
            itemBuilder: (context, index) {
              final story = widget.stories[index];
              return GestureDetector(
                onTapUp: (details) {
                  final screenWidth = MediaQuery.of(context).size.width;
                  if (details.globalPosition.dx < screenWidth / 3) {
                    _prevStory();
                  } else if (details.globalPosition.dx > screenWidth * 2 / 3) {
                    _nextStory();
                  }
                },
                onLongPress: () {
                  _showReplySheet(context, story);
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    InteractiveViewer(
                      minScale: 1.0,
                      maxScale: 3.0,
                      child: Image.network(
                        story.mediaUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.broken_image_rounded, color: Colors.white54, size: 64),
                                const SizedBox(height: 16),
                                Text('Failed to load', style: TextStyle(color: Colors.white54)),
                              ],
                            ),
                          );
                        },
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Center(
                            child: CircularProgressIndicator(
                              value: loadingProgress.expectedTotalBytes != null
                                  ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                  : null,
                              color: Colors.white,
                            ),
                          );
                        },
                      ),
                    ),
                    if (story.caption != null && story.caption!.isNotEmpty)
                      Positioned(
                        bottom: 80,
                        left: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            story.caption!,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          SafeArea(
            child: Column(
              children: [
                _buildProgressBars(),
                _buildHeader(),
              ],
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Container(
                height: 60,
                color: Colors.transparent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBars() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: List.generate(widget.stories.length, (index) {
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: AnimatedBuilder(
                animation: _progressController,
                builder: (context, child) {
                  double value;
                  if (index < _currentIndex) {
                    value = 1.0;
                  } else if (index > _currentIndex) {
                    value = 0.0;
                  } else {
                    value = _progressController.value;
                  }
                  return LinearProgressIndicator(
                    value: value,
                    backgroundColor: Colors.white30,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    minHeight: 2,
                  );
                },
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              widget.authorJid.isNotEmpty ? widget.authorJid[0].toUpperCase() : '?',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.authorJid,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: () {
              widget.onClose?.call();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  void _showReplySheet(BuildContext context, Story story) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Reply to ${widget.authorJid}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text('Send a direct message to this person'),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}
