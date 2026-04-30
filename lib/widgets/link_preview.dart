import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class LinkPreview extends StatefulWidget {
  final String url;
  const LinkPreview({super.key, required this.url});

  @override
  State<LinkPreview> createState() => _LinkPreviewState();
}

class _LinkPreviewState extends State<LinkPreview> {
  Map<String, String>? _metadata;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _fetchMetadata();
  }

  Future<void> _fetchMetadata() async {
    try {
      final uri = Uri.parse(widget.url);
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final htmlStr = response.body;
        final title = _extractMeta(htmlStr, 'og:title') ?? _extractTitle(htmlStr);
        final desc = _extractMeta(htmlStr, 'og:description');
        final image = _extractMeta(htmlStr, 'og:image');

        if (title != null || desc != null || image != null) {
          if (mounted) {
            setState(() {
              _metadata = {
                if (title != null) 'title': title,
                if (desc != null) 'description': desc,
                if (image != null) 'image': image.startsWith('/') 
                    ? '${uri.scheme}://${uri.host}$image' 
                    : image,
              };
              _isLoading = false;
            });
          }
          return;
        }
      }
    } catch (_) {}
    
    if (mounted) {
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    }
  }

  String? _extractMeta(String html, String property) {
    final regex = RegExp('<meta[^>]+property=["\']$property["\'][^>]+content=["\'](.*?)["\']', caseSensitive: false);
    final match = regex.firstMatch(html);
    if (match != null) return match.group(1);
    
    // Reverse order (content before property)
    final regexRev = RegExp('<meta[^>]+content=["\'](.*?)["\'][^>]+property=["\']$property["\']', caseSensitive: false);
    final matchRev = regexRev.firstMatch(html);
    return matchRev?.group(1);
  }

  String? _extractTitle(String html) {
    final regex = RegExp('<title>(.*?)</title>', caseSensitive: false);
    final match = regex.firstMatch(html);
    return match?.group(1);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        width: 250,
        height: 60,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_hasError || _metadata == null) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: () => launchUrl(Uri.parse(widget.url)),
      child: Container(
        width: 280,
        margin: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_metadata!['image'] != null)
              Image.network(
                _metadata!['image']!,
                width: double.infinity,
                height: 120,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_metadata!['title'] != null)
                    Text(
                      _metadata!['title']!,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (_metadata!['description'] != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _metadata!['description']!,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
