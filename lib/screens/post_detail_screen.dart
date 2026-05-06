import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/space_models.dart';
import '../services/spaces_service.dart';
import '../services/auth_service.dart';
import 'package:provider/provider.dart';

class PostDetailScreen extends StatefulWidget {
  final SpaceItem post;
  final SpaceNode space;
  final SpacesService spacesService;
  final List<SpaceItem> allItems;

  const PostDetailScreen({
    super.key,
    required this.post,
    required this.space,
    required this.spacesService,
    required this.allItems,
  });

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  List<SpaceItem> _replies = [];
  bool _isLoadingReplies = true;
  final _replyController = TextEditingController();
  bool _isPosting = false;

  @override
  void initState() {
    super.initState();
    _loadReplies();
  }

  Future<void> _loadReplies() async {
    // 1. Initial synchronous load from local allItems
    final localReplies = widget.allItems.where((i) => i.replyToId == widget.post.id).toList();
    
    if (mounted) {
      setState(() {
        _replies = localReplies;
      });
    }

    // 2. Fetch external comment threads if a node is provided
    if (widget.post.commentNode != null) {
      final targetDomain = widget.post.commentService ?? widget.space.domain;
      try {
        final remoteReplies = await widget.spacesService.fetchSpaceContent(targetDomain, widget.post.commentNode!);
        
        // Deduplicate and merge
        final Map<String, SpaceItem> merged = {};
        for (var r in _replies) {
          merged[r.id] = r;
        }
        for (var r in remoteReplies) {
          merged[r.id] = r;
        }
        
        if (mounted) {
          setState(() {
            _replies = merged.values.toList();
          });
        }
      } catch (e) {
        debugPrint('Error fetching remote replies: $e');
      }
    }

    if (mounted) {
      setState(() {
        _replies.sort((a, b) => (a.publishedDate ?? DateTime.now()).compareTo(b.publishedDate ?? DateTime.now()));
        _isLoadingReplies = false;
      });
    }
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 365) return '${(diff.inDays / 365).floor()}y ago';
    if (diff.inDays > 30)  return '${(diff.inDays / 30).floor()}mo ago';
    if (diff.inDays > 0)   return '${diff.inDays}d ago';
    if (diff.inHours > 0)  return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  }

  Future<void> _postReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty) return;

    setState(() => _isPosting = true);

    final targetDomain = widget.post.commentService ?? widget.space.domain;
    final targetNode = widget.post.commentNode ?? widget.space.node;

    final auth = context.read<AuthService>();
    final authorName = auth.getResolvedNickname(null);
    var success = await widget.spacesService.postReply(
      targetDomain,
      targetNode,
      text,
      replyToId: widget.post.id,
      authorName: authorName,
    );

    // Fallback: If the post specified a comment node but it failed (e.g. node doesn't exist),
    // fallback to publishing the reply on the main space node as per XEP-0277.
    if (!success && widget.post.commentNode != null) {
      success = await widget.spacesService.postReply(
        widget.space.domain,
        widget.space.node,
        text,
        replyToId: widget.post.id,
        authorName: authorName,
        autoCreateNode: false,
      );
    }

    if (mounted) {
      setState(() => _isPosting = false);
      if (success) {
        _replyController.clear();
        setState(() {
          _replies.add(SpaceItem(
            id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
            type: 'entry',
            rawContent: text,
            author: 'You',
            publishedDate: DateTime.now(),
            replyToId: widget.post.id,
          ));
        });
        FocusScope.of(context).unfocus();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to post reply')));
      }
    }
  }

  Widget _buildContent(ThemeData theme, SpaceItem item, {bool isReply = false}) {
    String? body = item.rawContent?.trim();
    if (body == null || body.isEmpty) body = item.description?.trim();
    if (body == null || body.isEmpty) return const SizedBox.shrink();

    String display = body;
    display = display.replaceAll(RegExp(r'<[^>]+>'), '').trim(); // simplistic HTML strip

    final title = item.name?.trim() ?? '';
    if (title.isNotEmpty && display.startsWith(title)) {
      display = display.substring(title.length).trimLeft();
    }

    if (display.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.fromLTRB(16, isReply ? 4 : 8, 16, 8),
      child: MarkdownBody(
        data: display,
        styleSheet: MarkdownStyleSheet(
          p: TextStyle(fontSize: isReply ? 14 : 15, color: theme.colorScheme.onSurface, height: 1.5),
          a: TextStyle(color: theme.colorScheme.primary),
        ),
        onTapLink: (text, href, title) {
          if (href != null) {
            try { launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication); } catch (_) {}
          }
        },
      ),
    );
  }

  Widget _buildReplyTile(ThemeData theme, SpaceItem reply) {
    final authorInitial = (reply.author?.isNotEmpty == true) ? reply.author![0].toUpperCase() : '?';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  child: Text(authorInitial, style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.bold, color: theme.colorScheme.onSecondaryContainer)),
                ),
                const SizedBox(width: 8),
                Text(reply.author ?? 'Anonymous', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 8),
                if (reply.publishedDate != null)
                  Text(_timeAgo(reply.publishedDate!), style: GoogleFonts.inter(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          _buildContent(theme, reply, isReply: true),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final authorInitial = (widget.post.author?.isNotEmpty == true) ? widget.post.author![0].toUpperCase() : '?';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Thread'),
        titleSpacing: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                // Parent Post
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Text(authorInitial, style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer)),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.post.author ?? 'Anonymous', style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 16)),
                          if (widget.post.publishedDate != null)
                            Text(_timeAgo(widget.post.publishedDate!), style: GoogleFonts.inter(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ],
                  ),
                ),
                if (widget.post.name?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(widget.post.name!, style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 20, height: 1.25)),
                  ),
                _buildContent(theme, widget.post),
                
                if (widget.post.imageUrl != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(widget.post.imageUrl!, fit: BoxFit.cover),
                    ),
                  ),

                const Divider(thickness: 4),

                // Replies Section
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Text('${_replies.length} Replies', style: GoogleFonts.inter(fontWeight: FontWeight.w900)),
                      if (_isLoadingReplies) ...[
                        const SizedBox(width: 12),
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      ]
                    ],
                  ),
                ),
                if (_replies.isEmpty && !_isLoadingReplies)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text('No replies yet. Be the first!', style: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                  )
                else
                  ..._replies.map((r) => _buildReplyTile(theme, r)),
              ],
            ),
          ),

          // Reply Input Area
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, -2))
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replyController,
                      decoration: InputDecoration(
                        hintText: 'Add a reply...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _postReply(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _isPosting 
                    ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(
                        icon: const Icon(Icons.send_rounded),
                        color: theme.colorScheme.primary,
                        onPressed: _postReply,
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

