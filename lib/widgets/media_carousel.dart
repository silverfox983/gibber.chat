import 'package:flutter/material.dart';

/// A scrollable list of images extracted from a space.
class MediaCarousel extends StatelessWidget {
  final List<String> mediaUrls;
  final double imageHeight;

  const MediaCarousel({
    required this.mediaUrls,
    this.imageHeight = 240,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (mediaUrls.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.4),
            ),
            const SizedBox(height: 12),
            Text(
              'No media in this space',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: mediaUrls.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.network(
            mediaUrls[index],
            height: imageHeight,
            width: double.infinity,
            fit: BoxFit.cover,
            loadingBuilder: (_, child, progress) {
              if (progress == null) return child;
              return Container(
                height: imageHeight,
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(child: CircularProgressIndicator()),
              );
            },
            errorBuilder: (_, _, _) => Container(
              height: imageHeight,
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(
                child: Icon(Icons.broken_image_rounded, size: 48),
              ),
            ),
          ),
        );
      },
    );
  }
}
