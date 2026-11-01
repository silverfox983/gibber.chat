import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';


import '../services/auth_service.dart';
import '../services/spaces_service.dart';

import '../models/space_models.dart';
import '../models/unified_community.dart';

class CreatePostDialog extends StatefulWidget {
  const CreatePostDialog({
    super.key,
    required this.spacesService,
    required this.space,
    required this.onSuccess,
    required this.authService,
    this.editItem,
  });

  final SpacesService spacesService;
  final SpaceNode space;
  final VoidCallback onSuccess;
  final AuthService authService;
  final SpaceItem? editItem;

  @override
  State<CreatePostDialog> createState() => _CreatePostDialogState();
}

class _CreatePostDialogState extends State<CreatePostDialog>
    with SingleTickerProviderStateMixin {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _tagsController = TextEditingController();
  bool _isPublishing = false;
  bool _previewMode = false;
  String? _attachedImageUrl;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() => _previewMode = _tabController.index == 1));

    if (widget.editItem != null) {
      _titleController.text = widget.editItem!.name ?? '';
      _contentController.text = widget.editItem!.rawContent ?? widget.editItem!.description ?? '';
      final cats = widget.editItem!.categories;
      _tagsController.text = cats.join(', ');
      _attachedImageUrl = widget.editItem!.imageUrl;
    } else {
      // Restore draft asynchronously (skip when editing existing post)
      widget.spacesService.loadDraft(widget.space.node).then((draft) {
        if (draft != null && mounted) {
          setState(() {
            _titleController.text = draft['title'] ?? '';
            _contentController.text = draft['content'] ?? '';
            _tagsController.text = draft['tags'] ?? '';
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _tagsController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _autosaveDraft() {
    widget.spacesService.saveDraft(
      widget.space.node,
      title: _titleController.text,
      content: _contentController.text,
      tags: _tagsController.text,
    );
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (file == null || !mounted) return;
      // For now, store the local path as a placeholder. In production,
      // upload via XEP-0363 HTTP File Upload and replace with the URL.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image selected. It will be attached on publish.')),
      );
      setState(() => _attachedImageUrl = file.path);
    } catch (e) {
      debugPrint('Image pick error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = _contentController.text;
    final wordCount = content.trim().isEmpty ? 0 : content.trim().split(RegExp(r'\s+')).length;
    final hasContent = content.trim().isNotEmpty;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!hasContent) {
          // Nothing to discard — just clear draft and close
          await widget.spacesService.deleteDraft(widget.space.node);
          if (mounted) Navigator.of(context).pop();
          return;
        }
        final discard = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('Your draft will be saved and restored next time.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true && mounted) {
          await widget.spacesService.deleteDraft(widget.space.node);
          if (mounted) Navigator.of(context).pop();
        }
      },
      child: Dialog.fullscreen(
        child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
              widget.editItem != null ? 'Edit Post' : 'New Post in ${widget.space.name}',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (_isPublishing)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  onPressed: _handlePublish,
                  icon: Icon(widget.editItem != null ? Icons.check_rounded : Icons.send_rounded, size: 16),
                  label: Text(widget.editItem != null ? 'Save' : 'Publish'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                ),
              ),
          ],
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.edit_rounded, size: 18), text: 'Write'),
              Tab(icon: Icon(Icons.preview_rounded, size: 18), text: 'Preview'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            // ── Write Tab ──
            SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Title
                TextField(
                  controller: _titleController,
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
                  decoration: InputDecoration(
                    hintText: 'Post title (optional)...',
                    hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4), fontWeight: FontWeight.w900, fontSize: 20),
                    border: InputBorder.none,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) { setState(() {}); _autosaveDraft(); },
                ),
                Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
                const SizedBox(height: 8),
                // Tags
                TextField(
                  controller: _tagsController,
                  style: TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Tags (comma separated)...',
                    hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 14),
                    border: InputBorder.none,
                    prefixIcon: Icon(Icons.tag_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    isDense: true,
                  ),
                  onChanged: (_) { setState(() {}); _autosaveDraft(); },
                ),
                Divider(color: theme.dividerColor.withValues(alpha: 0.3)),
                const SizedBox(height: 8),
                // Markdown formatting toolbar
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _toolbarBtn(Icons.format_bold_rounded, 'Bold', () => _insertMarkdown('**', '**')),
                    _toolbarBtn(Icons.format_italic_rounded, 'Italic', () => _insertMarkdown('_', '_')),
                    _toolbarBtn(Icons.code_rounded, 'Code', () => _insertMarkdown('`', '`')),
                    _toolbarBtn(Icons.format_list_bulleted_rounded, 'List', () => _insertMarkdown('\n- ', '')),
                    _toolbarBtn(Icons.format_list_numbered_rounded, 'Numbered', () => _insertMarkdown('\n1. ', '')),
                    _toolbarBtn(Icons.link_rounded, 'Link', () => _insertMarkdown('[', '](url)')),
                    _toolbarBtn(Icons.format_quote_rounded, 'Quote', () => _insertMarkdown('\n> ', '')),
                    _toolbarBtn(Icons.title_rounded, 'Heading', () => _insertMarkdown('\n## ', '')),
                  ]),
                ),
                const SizedBox(height: 8),
                // Body
                TextField(
                  controller: _contentController,
                  maxLines: null,
                  minLines: 10,
                  style: TextStyle(fontSize: 16, height: 1.6),
                  decoration: InputDecoration(
                    hintText: "What's on your mind?\n\nMarkdown is supported: **bold**, _italic_, [links](url)",
                    hintStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4), fontSize: 15, height: 1.6),
                    border: InputBorder.none,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                // Attached image preview
                if (_attachedImageUrl != null)
                  Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _attachedImageUrl!.startsWith('http')
                          ? Image.network(_attachedImageUrl!, height: 180, width: double.infinity, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(height: 180, color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(child: Icon(Icons.image_rounded, size: 40))))
                          : kIsWeb ? const SizedBox.shrink() : Image.file(File(_attachedImageUrl!), height: 180, width: double.infinity, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(height: 180, color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(child: Icon(Icons.image_rounded, size: 40)))),
                    ),
                    Positioned(top: 8, right: 8,
                      child: GestureDetector(
                        onTap: () => setState(() => _attachedImageUrl = null),
                        child: Container(padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                          child: const Icon(Icons.close_rounded, color: Colors.white, size: 16)),
                      )),
                  ]),
              ]),
            ),
            // ── Preview Tab ──
            SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_titleController.text.isNotEmpty) ...[
                  Text(_titleController.text, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 24, height: 1.2)),
                  const SizedBox(height: 16),
                ],
                if (content.isEmpty)
                  Text('Nothing to preview yet. Write something in the Write tab.',
                      style: TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5), fontSize: 15))
                else
                  MarkdownBody(
                    data: content,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(fontSize: 16, color: theme.colorScheme.onSurface, height: 1.6),
                      a: TextStyle(color: theme.colorScheme.primary),
                    ),
                    onTapLink: (text, href, title) {
                      if (href != null) launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
                    },
                  ),
              ]),
            ),
          ],
        ),
        bottomNavigationBar: _previewMode ? null : BottomAppBar(
          child: Row(children: [
            IconButton(
              tooltip: 'Attach Image',
              icon: Icon(Icons.image_rounded, color: _attachedImageUrl != null ? theme.colorScheme.primary : null),
              onPressed: _pickImage,
            ),
            IconButton(
              tooltip: 'Bold',
              icon: const Icon(Icons.format_bold_rounded),
              onPressed: () => _insertMarkdown('**', '**'),
            ),
            IconButton(
              tooltip: 'Italic',
              icon: const Icon(Icons.format_italic_rounded),
              onPressed: () => _insertMarkdown('_', '_'),
            ),
            IconButton(
              tooltip: 'Link',
              icon: const Icon(Icons.link_rounded),
              onPressed: () => _insertMarkdown('[', '](url)'),
            ),
            IconButton(
              tooltip: 'Code',
              icon: const Icon(Icons.code_rounded),
              onPressed: () => _insertMarkdown('`', '`'),
            ),
            const Spacer(),
            Text('$wordCount w · ${content.length} ch',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(width: 12),
          ]),
        ),
      ),
    ),
  );
  }

  Widget _toolbarBtn(IconData icon, String label, VoidCallback onTap) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }

  void _insertMarkdown(String prefix, String suffix) {
    final ctrl = _contentController;
    final sel = ctrl.selection;
    final text = ctrl.text;
    final selected = sel.isValid ? text.substring(sel.start, sel.end) : '';
    final replacement = '$prefix$selected$suffix';
    final newText = text.replaceRange(sel.isValid ? sel.start : text.length, sel.isValid ? sel.end : text.length, replacement);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: (sel.isValid ? sel.start : text.length) + prefix.length + selected.length),
    );
    setState(() {});
  }

  Future<void> _handlePublish() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Post content cannot be empty')));
      return;
    }

    setState(() => _isPublishing = true);

    try {
      String? finalImageUrl = _attachedImageUrl;

      // If we have a local file attached, upload it first via XEP-0363
      if (_attachedImageUrl != null && !_attachedImageUrl!.startsWith('http') && !kIsWeb) {
        final uploadService = widget.authService.activeUploadService;
        if (uploadService == null) {
          throw Exception('HTTP Upload service not available on this server.');
        }

        final file = File(_attachedImageUrl!);
        final fileName = file.path.split(RegExp(r'[/\\]')).last;
        final size = await file.length();
        final contentType = 'image/${fileName.split('.').last.toLowerCase()}';

        final slot = await uploadService.requestUploadSlot(fileName, size, contentType: contentType);
        if (slot == null) {
          throw Exception('Failed to request upload slot from server.');
        }

        final uploadSuccess = await uploadService.uploadFile(slot['put']!, file, contentType);
        if (!uploadSuccess) {
          throw Exception('Failed to upload image to server.');
        }

        finalImageUrl = slot['get'];
      }

      final tags = _tagsController.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

      final isEditing = widget.editItem != null;
      final success = await widget.spacesService.publishMicroblogEntry(
        widget.space.domain,
        widget.space.node,
        content: content,
        title: _titleController.text.trim(),
        imageUrl: finalImageUrl,
        categories: tags.isNotEmpty ? tags : null,
        itemId: isEditing ? widget.editItem!.id : null,
      );

      if (mounted) {
        setState(() => _isPublishing = false);
        if (success) {
          if (!isEditing) await widget.spacesService.deleteDraft(widget.space.node);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(isEditing ? 'Post updated!' : 'Post published!')),
          );
          if (mounted) Navigator.pop(context);
          widget.onSuccess();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(isEditing ? 'Failed to update post.' : 'Failed to publish. Check permissions.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isPublishing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}
