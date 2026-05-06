import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:html2md/html2md.dart' as html2md;
import 'package:share_plus/share_plus.dart';

import '../models/space_models.dart';
import '../services/spaces_service.dart';
import '../services/auth_service.dart';

class PostThreadScreen extends StatefulWidget {
  final SpaceItem post;
  final SpaceNode space;
  final SpacesService spacesService;

  const PostThreadScreen({
    super.key,
    required this.post,
    required this.space,
    required this.spacesService,
  });

  @override
  State<PostThreadScreen> createState() => _PostThreadScreenState();
}

class _PostThreadScreenState extends State<PostThreadScreen> {
  List<SpaceItem>? _replies;
  bool _loading = true;
  final TextEditingController _replyCtrl = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _loadReplies();
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadReplies() async {
    setState(() => _loading = true);
    try {
      final targetDomain = widget.post.commentService ?? widget.space.domain;
      final targetNode = widget.post.commentNode ?? widget.space.node;
      final items = await widget.spacesService.fetchSpaceContent(
        targetDomain, targetNode,
        spaceContext: widget.space,
      );
      if (mounted) {
        setState(() {
          _replies = items.where((i) =>
            i.type == 'entry' && i.id != widget.post.id
          ).toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _replies = []; _loading = false; });
    }
  }

  Future<void> _postReply() async {
    final text = _replyCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _posting = true);
    final targetDomain = widget.post.commentService ?? widget.space.domain;
    final targetNode = widget.post.commentNode ?? widget.space.node;
    final auth = context.read<AuthService>();
    final authorName = auth.getResolvedNickname(null);

    var ok = await widget.spacesService.postReply(
      targetDomain, targetNode, text,
      replyToId: widget.post.id,
      authorName: authorName,
    );
    if (!ok && widget.post.commentNode != null) {
      ok = await widget.spacesService.postReply(
        widget.space.domain, widget.space.node, text,
        replyToId: widget.post.id,
        authorName: authorName,
        autoCreateNode: false,
      );
    }
    if (mounted) {
      setState(() => _posting = false);
      if (ok) {
        _replyCtrl.clear();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reply posted!')));
        _loadReplies();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to post reply.')));
      }
    }
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 365) return '${(diff.inDays / 365).floor()}y ago';
    if (diff.inDays > 30) return '${(diff.inDays / 30).floor()}mo ago';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final post = widget.post;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Thread', style: GoogleFonts.inter(fontWeight: FontWeight.w900)),
        centerTitle: false,
        elevation: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => Share.share(
              '${post.name ?? 'Post'} by ${post.author ?? 'Anonymous'}\n\n${post.description ?? ''}',
              subject: post.name,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadReplies,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  // ── Original Post ──
                  _buildOriginalPost(theme, post),
                  const SizedBox(height: 8),
                  Divider(color: theme.dividerColor.withValues(alpha: 0.4)),
                  // ── Reply count ──
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(children: [
                      Icon(Icons.chat_bubble_outline_rounded, size: 16,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        _loading ? 'Loading replies…' :
                          '${_replies?.length ?? 0} ${(_replies?.length ?? 0) == 1 ? 'Reply' : 'Replies'}',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w800,
                            fontSize: 13, color: theme.colorScheme.primary),
                      ),
                      const Spacer(),
                      if (!_loading)
                        TextButton.icon(
                          onPressed: _loadReplies,
                          icon: const Icon(Icons.refresh_rounded, size: 15),
                          label: const Text('Refresh', style: TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8)),
                        ),
                    ]),
                  ),
                  // ── Replies ──
                  if (_loading)
                    const Center(child: Padding(
                        padding: EdgeInsets.all(32),
                        child: CircularProgressIndicator()))
                  else if (_replies == null || _replies!.isEmpty)
                    Center(child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(children: [
                        Icon(Icons.chat_bubble_outline_rounded, size: 48,
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text('Be the first to reply!',
                            style: GoogleFonts.inter(
                                color: theme.colorScheme.onSurfaceVariant, fontSize: 15)),
                      ]),
                    ))
                  else
                    ..._replies!.map((r) => _buildReplyCard(theme, r)),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
          // ── Reply Composer ──
          _buildReplyComposer(theme),
        ],
      ),
    );
  }

  Widget _buildOriginalPost(ThemeData theme, SpaceItem post) {
    String content = '';
    if (post.rawContent != null && post.rawContent!.isNotEmpty) {
      try {
        content = post.contentType == 'text/html'
            ? html2md.convert(post.rawContent!)
            : post.rawContent!;
      } catch (_) { content = post.rawContent!; }
    } else if (post.description != null) {
      content = post.description!;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Author row
        Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Text(
              post.author?.isNotEmpty == true ? post.author![0].toUpperCase() : '?',
              style: GoogleFonts.inter(fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(post.author ?? 'Anonymous',
                style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 14)),
            if (post.publishedDate != null)
              Text(_timeAgo(post.publishedDate!),
                  style: GoogleFonts.inter(
                      fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
          ])),
          // Reactions summary
          if (post.reactions.isNotEmpty)
            Wrap(spacing: 4, children: post.reactions.entries
                .where((e) => e.value > 0)
                .take(3)
                .map((e) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: theme.dividerColor)),
                      child: Text('${e.key} ${e.value}',
                          style: const TextStyle(fontSize: 12)),
                    ))
                .toList()),
        ]),
        if (post.name?.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          Text(post.name!,
              style: GoogleFonts.inter(fontWeight: FontWeight.w900, fontSize: 20, height: 1.2)),
        ],
        if (content.isNotEmpty) ...[
          const SizedBox(height: 8),
          MarkdownBody(
            data: content,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(fontSize: 15, color: theme.colorScheme.onSurface, height: 1.55),
              a: TextStyle(color: theme.colorScheme.primary),
            ),
            onTapLink: (_, href, __) {
              if (href != null) {
                try { launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication); } catch (_) {}
              }
            },
          ),
        ],
        // Category chips
        if (post.categories.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, children: post.categories.map((c) => Chip(
            label: Text(c, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSecondaryContainer)),
            backgroundColor: theme.colorScheme.secondaryContainer,
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          )).toList()),
        ],
        // Copy action
        const SizedBox(height: 8),
        Row(children: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: '${post.name ?? ''}\n\n$content'));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')));
            },
            icon: const Icon(Icons.copy_rounded, size: 15),
            label: const Text('Copy', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4)),
          ),
          TextButton.icon(
            onPressed: () => Share.share('${post.name ?? ''}\n\n$content'),
            icon: const Icon(Icons.ios_share_rounded, size: 15),
            label: const Text('Share', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4)),
          ),
        ]),
      ]),
    );
  }

  Widget _buildReplyCard(ThemeData theme, SpaceItem reply) {
    String content = reply.description ?? reply.rawContent ?? '';
    if (reply.rawContent != null && reply.rawContent!.isNotEmpty) {
      try {
        content = reply.contentType == 'text/html'
            ? html2md.convert(reply.rawContent!)
            : reply.rawContent!;
      } catch (_) {}
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: theme.colorScheme.tertiaryContainer,
            child: Text(
              reply.author?.isNotEmpty == true ? reply.author![0].toUpperCase() : '?',
              style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 12,
                  color: theme.colorScheme.onTertiaryContainer),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(reply.author ?? 'Anonymous',
                style: GoogleFonts.inter(fontWeight: FontWeight.bold, fontSize: 13)),
            if (reply.publishedDate != null)
              Text(_timeAgo(reply.publishedDate!),
                  style: GoogleFonts.inter(fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant)),
          ])),
          GestureDetector(
            onTap: () => Clipboard.setData(ClipboardData(text: content)),
            child: Icon(Icons.copy_rounded, size: 16,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
          ),
        ]),
        if (content.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(content, style: GoogleFonts.inter(fontSize: 14, height: 1.5,
              color: theme.colorScheme.onSurface)),
        ],
      ]),
    );
  }

  Widget _buildReplyComposer(ThemeData theme) {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16,
          12 + MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4))),
      ),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _replyCtrl,
            maxLines: 4,
            minLines: 1,
            decoration: InputDecoration(
              hintText: 'Write a reply…',
              hintStyle: GoogleFonts.inter(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
          ),
        ),
        const SizedBox(width: 10),
        _posting
            ? const SizedBox(width: 40, height: 40,
                child: CircularProgressIndicator(strokeWidth: 2))
            : FilledButton(
                onPressed: _postReply,
                style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(12)),
                child: const Icon(Icons.send_rounded, size: 20),
              ),
      ]),
    );
  }
}
