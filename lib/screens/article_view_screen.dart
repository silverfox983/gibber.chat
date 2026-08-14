import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:html2md/html2md.dart' as html2md;
import 'package:intl/intl.dart';
import '../services/spaces_service.dart';
import '../models/space_models.dart';

class ArticleViewScreen extends StatelessWidget {
  final SpaceItem item;
  final SpacesService? spacesService;

  const ArticleViewScreen({super.key, required this.item, this.spacesService});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // For Movim, the rawContent could be HTML. flutter_markdown won't render raw HTML perfectly,
    // but typically Movim items are somewhat clean. We can display rawContent or description.
    final content =
        item.rawContent ?? item.description ?? 'No content provided.';

    final formattedDate = item.publishedDate != null
        ? DateFormat.yMMMMd().add_jm().format(item.publishedDate!)
        : null;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: item.imageUrl != null ? 350.0 : 150.0,
            floating: false,
            pinned: true,
            stretch: true,
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [
                StretchMode.zoomBackground,
                StretchMode.blurBackground,
              ],
              background: item.imageUrl != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(
                          item.imageUrl!,
                          fit: BoxFit.cover,
                          cacheWidth: 800,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                              ),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                theme.colorScheme.surface.withValues(
                                  alpha: 0.8,
                                ),
                                theme.colorScheme.surface,
                              ],
                              stops: const [0.5, 0.8, 1.0],
                            ),
                          ),
                        ),
                      ],
                    )
                  : Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            theme.colorScheme.primaryContainer,
                            theme.colorScheme.surface,
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
            ),
            actions: [
              if (item.url != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: IconButton.filledTonal(
                    icon: const Icon(Icons.open_in_browser_rounded),
                    tooltip: 'Open in Browser',
                    onPressed: () async {
                      final uri = Uri.parse(item.url!);
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                  ),
                ),
            ],
          ),
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24.0,
                    vertical: 16.0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name ?? 'Untitled',
                        style: theme.textTheme.headlineLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: theme.colorScheme.onSurface,
                          letterSpacing: -0.5,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 24,
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Text(
                              (item.author != null && item.author!.isNotEmpty)
                                  ? item.author![0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.author ?? 'Unknown Author',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                if (formattedDate != null)
                                  Text(
                                    formattedDate,
                                    style: TextStyle(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      fontSize: 14,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32.0),
                        child: Divider(),
                      ),
                      MarkdownBody(
                        data: html2md.convert(content),
                        selectable: true,
                        onTapLink: (text, href, title) async {
                          if (href != null) {
                            final uri = Uri.parse(href);
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri);
                            }
                          }
                        },
                        styleSheet: MarkdownStyleSheet(
                          p: TextStyle(
                            fontSize: 18,
                            height: 1.8,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.9,
                            ),
                            letterSpacing: 0.2,
                          ),
                          h1: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            color: theme.colorScheme.onSurface,
                            height: 1.3,
                          ),
                          h2: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                            height: 1.3,
                          ),
                          h3: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                            height: 1.3,
                          ),
                          blockquote: TextStyle(
                            fontSize: 18,
                            fontStyle: FontStyle.italic,
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.6,
                          ),
                          blockquoteDecoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: theme.colorScheme.primary,
                                width: 4,
                              ),
                            ),
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.3),
                            borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(8),
                              bottomRight: Radius.circular(8),
                            ),
                          ),
                          code: TextStyle(
                            fontFamily: 'monospace',
                            backgroundColor: theme
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            color: theme.colorScheme.onSurface,
                            fontSize: 14,
                          ),
                          codeblockDecoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.dividerColor.withValues(alpha: 0.5),
                            ),
                          ),
                          listBullet: TextStyle(
                            color: theme.colorScheme.primary,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      if (item.commentNode != null &&
                          item.commentService != null &&
                          spacesService != null)
                        CommentsSection(
                          service: item.commentService!,
                          node: item.commentNode!,
                          spacesService: spacesService!,
                          parentId: item.id,
                        ),
                      const SizedBox(height: 80),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CommentsSection extends StatefulWidget {
  final String service;
  final String node;
  final SpacesService spacesService;
  final ScrollController? scrollController;
  final String? parentId;

  const CommentsSection({
    super.key,
    required this.service,
    required this.node,
    required this.spacesService,
    this.scrollController,
    this.parentId,
  });

  @override
  State<CommentsSection> createState() => _CommentsSectionState();
}

class _CommentsSectionState extends State<CommentsSection> {
  List<SpaceItem>? _comments;
  bool _isLoading = true;
  final TextEditingController _commentController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchComments();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _fetchComments() async {
    try {
      final comments = await widget.spacesService.fetchSpaceContent(
        widget.service,
        widget.node,
      );
      if (mounted) {
        setState(() {
          _comments = comments;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isLoading = true);
    final success = await widget.spacesService.publishMicroblogEntry(
      widget.service,
      widget.node,
      title: 'Comment',
      content: text,
      authorName: widget.spacesService.connection.fullJid.local,
      replyToId: widget.parentId,
    );

    if (success) {
      _commentController.clear();
      await _fetchComments();
    } else {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to post comment.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.comment_outlined, size: 20),
            const SizedBox(width: 12),
            Text(
              'Comments',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            if (_comments != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_comments!.length}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _commentController,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: 'Add a comment...',
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.3,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              icon: const Icon(Icons.send_rounded),
              onPressed: _postComment,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 24),
        if (_isLoading && (_comments == null || _comments!.isEmpty))
          const Center(child: CircularProgressIndicator())
        else if (_comments == null || _comments!.isEmpty)
          Center(
            child: Text(
              'No comments yet. Be the first to reply!',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: widget.scrollController == null
                ? const NeverScrollableScrollPhysics()
                : null,
            controller: widget.scrollController,
            itemCount: _comments!.length,
            itemBuilder: (context, index) {
              final comment = _comments![index];
              return Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: theme.colorScheme.secondaryContainer,
                          child: Text(
                            (comment.author != null &&
                                    comment.author!.isNotEmpty)
                                ? comment.author![0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            comment.author ?? 'Anonymous',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (comment.publishedDate != null)
                          Text(
                            DateFormat.yMMMd().format(comment.publishedDate!),
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    MarkdownBody(
                      data: html2md.convert(
                        comment.description ?? comment.rawContent ?? '',
                      ),
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(fontSize: 15, height: 1.5),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}
