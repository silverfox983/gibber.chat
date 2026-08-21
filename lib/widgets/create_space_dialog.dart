import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/space_models.dart';
import '../services/spaces_service.dart';
import '../services/auth_service.dart';

class CreateSpaceDialog extends StatefulWidget {
  final SpacesService spacesService;
  final String domain;
  final VoidCallback onSuccess;

  const CreateSpaceDialog({
    super.key,
    required this.spacesService,
    required this.domain,
    required this.onSuccess,
  });

  @override
  State<CreateSpaceDialog> createState() => _CreateSpaceDialogState();
}

class _CreateSpaceDialogState extends State<CreateSpaceDialog> {
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  final _bannerUrlController = TextEditingController();
  late final TextEditingController _domainController;
  late final TextEditingController _slugController;
  bool _isLoading = false;
  bool _domainChecked = false;
  bool _domainValid = false;
  bool _createChatRoom = true;

  @override
  void initState() {
    super.initState();
    final d = widget.domain;
    _domainController = TextEditingController(
      text: d.contains('.') ? 'pubsub.$d' : d,
    );
    _slugController = TextEditingController();
    _titleController.addListener(_onTitleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _validateDomain());
  }

  void _onTitleChanged() {
    final title = _titleController.text.trim();
    if (title.isNotEmpty && _slugController.text.isEmpty) {
      _slugController.text = _generateSlug(title);
    }
  }

  String _generateSlug(String title) {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s\-]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  @override
  void dispose() {
    _titleController.removeListener(_onTitleChanged);
    _titleController.dispose();
    _descController.dispose();
    _bannerUrlController.dispose();
    _domainController.dispose();
    _slugController.dispose();
    super.dispose();
  }

  Future<void> _validateDomain() async {
    final domain = _domainController.text.trim();
    if (domain.isEmpty || !domain.contains('.')) {
      setState(() { _domainValid = false; _domainChecked = true; });
      return;
    }
    setState(() { _domainChecked = false; });
    try {
      await widget.spacesService.discoverAllSpaces(domain).timeout(
        const Duration(seconds: 10),
        onTimeout: () => <SpaceNode>[],
      );
      if (mounted) {
        setState(() { _domainChecked = true; _domainValid = true; });
      }
    } catch (_) {
      if (mounted) {
        setState(() { _domainChecked = true; _domainValid = false; });
      }
    }
  }

  bool _showTitleError = false;
  bool _showSlugError = false;

  Future<void> _createSpace() async {
    final title = _titleController.text.trim();
    final slug = _slugController.text.trim().replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final targetDomain = _domainController.text.trim();

    bool hasError = false;
    if (title.isEmpty) { setState(() => _showTitleError = true); hasError = true; }
    if (slug.isEmpty) { setState(() => _showSlugError = true); hasError = true; }
    if (!_domainValid) { hasError = true; }
    if (hasError) return;

    setState(() { _isLoading = true; _showTitleError = false; _showSlugError = false; });

    final errorMessage = await widget.spacesService.createSpace(
      targetDomain,
      slug,
      title,
      description: _descController.text.trim(),
      topic: '',
      avatarUrl: null,
      bannerUrl: _bannerUrlController.text.trim(),
      accessModel: 'authorize',
      publishModel: 'publishers',
      createChatRoom: _createChatRoom,
    );

    setState(() => _isLoading = false);

    if (errorMessage == null) {
      if (mounted) {
        final auth = Provider.of<AuthService>(context, listen: false);
        auth.joinPersistedSpace(targetDomain, slug, title);

        Navigator.pop(context);

        final newSpace = SpaceNode(
          domain: targetDomain,
          node: slug,
          name: title,
          isSubscribed: true,
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Community "$title" created!'),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: 'OPEN',
              textColor: Colors.white,
              onPressed: () {
                context.pushNamed('spaceDetail', extra: {
                  'space': newSpace,
                  'spacesService': widget.spacesService,
                });
              },
            ),
          ),
        );
      }
      widget.onSuccess();
    } else {
      if (mounted) {
        String displayError = errorMessage;
        if (errorMessage.toLowerCase().contains('conflict') ||
            errorMessage.toLowerCase().contains('already exists')) {
          displayError = 'A community with this address already exists. Try a different name.';
          setState(() => _showSlugError = true);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(displayError),
            duration: const Duration(seconds: 6),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canCreate = _domainChecked && _domainValid && !_isLoading;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 40,
                  spreadRadius: -10,
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.workspaces_rounded,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Create Community',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Communities let you post, share, and discuss with others around a shared topic.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  _buildTextField(
                    controller: _titleController,
                    label: 'Community Title',
                    icon: Icons.title_rounded,
                    theme: theme,
                    errorText: _showTitleError ? 'Title is required' : null,
                    hintText: 'e.g. Open Source Projects',
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _slugController,
                    label: 'Address',
                    icon: Icons.link_rounded,
                    theme: theme,
                    errorText: _showSlugError ? 'Address is required' : null,
                    hintText: 'open-source-projects',
                    helperText: 'Only letters, numbers, and hyphens',
                    suffix: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        _domainController.text.trim().isNotEmpty
                            ? '@${_domainController.text.trim()}'
                            : '',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _descController,
                    label: 'Description (Optional)',
                    icon: Icons.description_rounded,
                    theme: theme,
                    maxLines: 2,
                    hintText: 'What is this community about?',
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _bannerUrlController,
                    label: 'Banner URL (Optional)',
                    icon: Icons.photo_size_select_actual_rounded,
                    theme: theme,
                    hintText: 'https://example.com/banner.jpg',
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.dns_rounded,
                          color: theme.colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Server',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _domainController.text.trim().isNotEmpty
                                    ? _domainController.text.trim()
                                    : widget.domain,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_domainChecked)
                          Icon(
                            _domainValid ? Icons.check_circle : Icons.error,
                            color: _domainValid ? Colors.green : theme.colorScheme.error,
                            size: 20,
                          )
                        else
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.chat_rounded,
                          color: theme.colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Create a chat room',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Members can join to chat in real-time',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: _createChatRoom,
                          onChanged: (v) => setState(() => _createChatRoom = v),
                          activeTrackColor: theme.colorScheme.primary.withValues(alpha: 0.5),
                          activeThumbColor: theme.colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_isLoading)
                    const Center(child: CircularProgressIndicator())
                  else
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Text(
                              'Cancel',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: canCreate ? _createSpace : null,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.onPrimary,
                              disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
                              disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              elevation: 0,
                            ),
                            child: const Text(
                              'Create',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required ThemeData theme,
    int maxLines = 1,
    String? helperText,
    String? errorText,
    String? hintText,
    Widget? suffix,
    void Function(String)? onChanged,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: TextStyle(
        color: theme.colorScheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        labelStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        prefixIcon: Icon(
          icon,
          color: errorText != null ? theme.colorScheme.error : theme.colorScheme.primary,
        ),
        helperText: helperText,
        helperMaxLines: 2,
        errorText: errorText,
        suffixIcon: suffix,
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: errorText != null
                ? theme.colorScheme.error
                : theme.colorScheme.outline.withValues(alpha: 0.2),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: errorText != null ? theme.colorScheme.error : theme.colorScheme.primary,
            width: 2,
          ),
        ),
      ),
    );
  }
}
