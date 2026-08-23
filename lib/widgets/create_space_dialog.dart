import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
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
  late final TextEditingController _domainController;
  late final String _spaceKey;

  int _currentStep = 0;
  bool _isLoading = false;
  bool _isUploading = false;
  bool _domainChecked = false;
  bool _domainValid = false;
  bool _showTitleError = false;

  String _accessModel = 'authorize';
  bool _createChatRoom = true;
  Uint8List? _avatarBytes;
  Uint8List? _bannerBytes;
  String? _avatarUrl;
  String? _bannerUrl;

  static const _stepLabels = ['Basics', 'Privacy', 'Appearance', 'Review'];
  static const _stepIcons = [
    Icons.edit_rounded,
    Icons.lock_rounded,
    Icons.palette_rounded,
    Icons.check_circle_rounded,
  ];

  @override
  void initState() {
    super.initState();
    final d = widget.domain;
    _domainController = TextEditingController(
      text: d.contains('.') ? 'spaces.$d' : d,
    );
    _spaceKey = _generateSpaceKey();
    WidgetsBinding.instance.addPostFrameCallback((_) => _validateDomain());
  }

  String _generateSpaceKey() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rnd = Random.secure();
    return List.generate(8, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _domainController.dispose();
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

  bool get _canProceed {
    switch (_currentStep) {
      case 0:
        return _domainChecked && _domainValid && _titleController.text.trim().isNotEmpty;
      case 1:
        return true;
      case 2:
        return true;
      case 3:
        return !_isLoading;
      default:
        return false;
    }
  }

  void _nextStep() {
    if (_currentStep == 0) {
      if (_titleController.text.trim().isEmpty) {
        setState(() => _showTitleError = true);
        return;
      }
      if (!_domainValid) return;
    }
    if (_currentStep < 3) {
      setState(() => _currentStep++);
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    }
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    setState(() => _avatarBytes = bytes);
    await _uploadImage(bytes, isAvatar: true);
  }

  Future<void> _pickBanner() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    setState(() => _bannerBytes = bytes);
    await _uploadImage(bytes, isAvatar: false);
  }

  Future<void> _uploadImage(Uint8List bytes, {required bool isAvatar}) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    final uploadService = auth.activeUploadService;
    if (uploadService == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('HTTP Upload not available on this server.')),
        );
      }
      return;
    }
    setState(() => _isUploading = true);
    try {
      final ext = 'png';
      final fileName = '${isAvatar ? "avatar" : "cover"}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final slot = await uploadService.requestUploadSlot(fileName, bytes.length, contentType: 'image/$ext');
      if (slot == null) throw Exception('Failed to request upload slot.');
      final uploaded = await uploadService.uploadFile(slot['put']!, bytes, 'image/$ext');
      if (!uploaded) throw Exception('Upload failed.');
      final url = slot['get']!;
      if (mounted) {
        setState(() {
          if (isAvatar) {
            _avatarUrl = url;
          } else {
            _bannerUrl = url;
          }
          _isUploading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
        setState(() => _isUploading = false);
      }
    }
  }

  Future<void> _createSpace() async {
    final title = _titleController.text.trim();
    final targetDomain = _domainController.text.trim();

    if (title.isEmpty || !_domainValid) return;

    setState(() => _isLoading = true);

    final errorMessage = await widget.spacesService.createSpace(
      targetDomain,
      _spaceKey,
      title,
      description: _descController.text.trim().isNotEmpty ? _descController.text.trim() : null,
      accessModel: _accessModel,
      createChatRoom: _createChatRoom,
      avatarUrl: _avatarUrl,
      coverUrl: _bannerUrl,
    );

    setState(() => _isLoading = false);

    if (errorMessage == null) {
      if (mounted) {
        final auth = Provider.of<AuthService>(context, listen: false);
        auth.joinPersistedSpace(targetDomain, _spaceKey, title);

        Navigator.pop(context);

        final newSpace = SpaceNode(
          domain: targetDomain,
          node: _spaceKey,
          name: title,
          isSubscribed: true,
          accessModel: _accessModel,
        );

        _showInviteKeyDialog(newSpace);
      }
      widget.onSuccess();
    } else {
      if (mounted) {
        final shortError = errorMessage.length > 160
            ? '${errorMessage.substring(0, 160)}...'
            : errorMessage;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(shortError),
            duration: const Duration(seconds: 10),
            backgroundColor: Theme.of(context).colorScheme.error,
            action: SnackBarAction(
              label: 'COPY',
              textColor: Colors.white,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: errorMessage));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Full error copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
          ),
        );
      }
    }
  }

  void _showInviteKeyDialog(SpaceNode space) {
    final inviteUri = 'xmpp:${space.domain}?;node=${space.node}';
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
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
                border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green.shade700.withValues(alpha: 0.2),
                    ),
                    child: Icon(Icons.check_circle_rounded, size: 36, color: Colors.green.shade700),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Space Created!',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: theme.colorScheme.onSurface),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Share this invite key with others to let them join.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Invite Key', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 4),
                        Text(
                          inviteUri,
                          style: TextStyle(fontSize: 13, fontFamily: 'monospace', fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: QrImageView(
                      data: inviteUri,
                      version: QrVersions.auto,
                      size: 140,
                      backgroundColor: Colors.white,
                      foregroundColor: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: inviteUri));
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Invite key copied!'), duration: Duration(seconds: 2)),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy_rounded, size: 16),
                          label: const Text('Copy'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            context.pushNamed('spaceDetail', extra: {
                              'space': space,
                              'spacesService': widget.spacesService,
                            });
                          },
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label: const Text('Open'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.onPrimary,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            width: 480,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildStepIndicator(theme),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: _buildCurrentStep(theme),
                  ),
                ),
                const Divider(height: 1),
                _buildBottomBar(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Row(
        children: List.generate(_stepLabels.length, (i) {
          final isActive = i == _currentStep;
          final isDone = i < _currentStep;
          return Expanded(
            child: GestureDetector(
              onTap: isDone ? () => setState(() => _currentStep = i) : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDone
                              ? theme.colorScheme.primary
                              : isActive
                                  ? theme.colorScheme.primary.withValues(alpha: 0.2)
                                  : theme.colorScheme.surfaceContainerHighest,
                          border: Border.all(
                            color: isActive
                                ? theme.colorScheme.primary
                                : isDone
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.outline.withValues(alpha: 0.3),
                            width: isActive ? 2 : 1,
                          ),
                        ),
                        child: Center(
                          child: isDone
                              ? Icon(Icons.check_rounded, size: 16, color: theme.colorScheme.onPrimary)
                              : Icon(_stepIcons[i], size: 16, color: isActive ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      if (i < _stepLabels.length - 1)
                        Container(
                          width: 24,
                          height: 2,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          color: isDone
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline.withValues(alpha: 0.3),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _stepLabels[i],
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isActive
                          ? theme.colorScheme.primary
                          : isDone
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildCurrentStep(ThemeData theme) {
    switch (_currentStep) {
      case 0:
        return _buildBasicsStep(theme);
      case 1:
        return _buildPrivacyStep(theme);
      case 2:
        return _buildAppearanceStep(theme);
      case 3:
        return _buildReviewStep(theme);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildBasicsStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Create Space',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Build a shared space with a linked chat room.',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        _buildTextField(
          controller: _titleController,
          label: 'Space Title',
          icon: Icons.title_rounded,
          theme: theme,
          errorText: _showTitleError ? 'Title is required' : null,
          hintText: 'e.g. Open Source Projects',
          onChanged: (_) => setState(() => _showTitleError = false),
        ),
        const SizedBox(height: 16),
        _buildTextField(
          controller: _descController,
          label: 'Description (optional)',
          icon: Icons.description_rounded,
          theme: theme,
          maxLines: 2,
          hintText: 'What is this space about?',
        ),
        const SizedBox(height: 16),
        _buildServerInfoCard(theme),
      ],
    );
  }

  Widget _buildPrivacyStep(ThemeData theme) {
    final models = [
      (
        id: 'authorize',
        icon: Icons.lock_rounded,
        title: 'Private (Recommended)',
        subtitle: 'Join requests require owner approval',
        desc: 'Users request to join; owners approve or deny',
      ),
      (
        id: 'open',
        icon: Icons.public_rounded,
        title: 'Public',
        subtitle: 'Anyone can discover and join',
        desc: 'Listed in directory, anyone can subscribe immediately',
      ),
      (
        id: 'whitelist',
        icon: Icons.admin_panel_settings_rounded,
        title: 'Whitelist Only',
        subtitle: 'Owners manually add members',
        desc: 'No join requests — owners control membership directly',
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Who can join?',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Choose how people join your space.',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        ...models.map((m) {
          final selected = _accessModel == m.id;
          return GestureDetector(
            onTap: () => setState(() => _accessModel = m.id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: selected
                    ? theme.colorScheme.primary.withValues(alpha: 0.1)
                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline.withValues(alpha: 0.2),
                  width: selected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected
                          ? theme.colorScheme.primary.withValues(alpha: 0.2)
                          : theme.colorScheme.surfaceContainerHighest,
                    ),
                    child: Icon(m.icon, size: 20, color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: theme.colorScheme.onSurface)),
                        const SizedBox(height: 2),
                        Text(m.subtitle, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 2),
                        Text(m.desc, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7))),
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(Icons.radio_button_checked_rounded, color: theme.colorScheme.primary, size: 20)
                  else
                    Icon(Icons.radio_button_off_rounded, color: theme.colorScheme.outline, size: 20),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(Icons.chat_rounded, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Create a chat room', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
                    Text('Members can chat in real-time', style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
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
      ],
    );
  }

  Widget _buildAppearanceStep(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Make it yours',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Add an avatar and banner to personalize your space.',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Center(
          child: GestureDetector(
            onTap: _pickAvatar,
            child: Stack(
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.surfaceContainerHighest,
                    border: Border.all(
                      color: theme.colorScheme.outline.withValues(alpha: 0.3),
                      width: 2,
                    ),
                    image: _avatarBytes != null
                        ? DecorationImage(image: MemoryImage(_avatarBytes!), fit: BoxFit.cover)
                        : null,
                  ),
                  child: _avatarBytes == null
                      ? Icon(Icons.camera_alt_rounded, size: 32, color: theme.colorScheme.onSurfaceVariant)
                      : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.colorScheme.surface, width: 2),
                    ),
                    child: Icon(Icons.edit_rounded, size: 14, color: theme.colorScheme.onPrimary),
                  ),
                ),
                if (_isUploading)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.5),
                      ),
                      child: const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text('Tap to add avatar', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: _pickBanner,
          child: Container(
            width: double.infinity,
            height: 140,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
                width: 2,
                style: _bannerBytes != null ? BorderStyle.solid : BorderStyle.none,
              ),
              image: _bannerBytes != null
                  ? DecorationImage(image: MemoryImage(_bannerBytes!), fit: BoxFit.cover)
                  : null,
            ),
            child: _bannerBytes == null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.panorama_rounded, size: 36, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text('Tap to add banner image', style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  )
                : Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Container(
                        margin: const EdgeInsets.all(8),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.edit_rounded, size: 14, color: Colors.white),
                            SizedBox(width: 4),
                            Text('Change', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildReviewStep(ThemeData theme) {
    final domain = _domainController.text.trim().isNotEmpty ? _domainController.text.trim() : widget.domain;
    final accessLabels = {
      'authorize': 'Private (approval required)',
      'open': 'Public (anyone can join)',
      'whitelist': 'Whitelist only (owner invites)',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Review & Create',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Confirm everything looks right.',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_bannerBytes != null)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: SizedBox(
                    width: double.infinity,
                    height: 120,
                    child: Image.memory(_bannerBytes!, fit: BoxFit.cover),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_avatarBytes != null)
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              image: DecorationImage(image: MemoryImage(_avatarBytes!), fit: BoxFit.cover),
                            ),
                          )
                        else
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: theme.colorScheme.primary.withValues(alpha: 0.2),
                            ),
                            child: Icon(Icons.workspaces_rounded, size: 22, color: theme.colorScheme.primary),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _titleController.text.trim(),
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: theme.colorScheme.onSurface),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '$_spaceKey@$domain',
                                style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (_descController.text.trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _descController.text.trim(),
                        style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 12),
                    _buildReviewRow(theme, Icons.lock_rounded, 'Access', accessLabels[_accessModel] ?? _accessModel),
                    _buildReviewRow(theme, Icons.dns_rounded, 'Server', domain),
                    _buildReviewRow(theme, Icons.chat_rounded, 'Chat room', _createChatRoom ? 'Yes' : 'No'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReviewRow(ThemeData theme, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('$label: ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _buildServerInfoCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.key_rounded, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Invitation key', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(
                      '$_spaceKey@${_domainController.text.trim().isNotEmpty ? _domainController.text.trim() : widget.domain}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, fontFamily: 'monospace', color: theme.colorScheme.onSurface),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.dns_rounded, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Server', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(
                      _domainController.text.trim().isNotEmpty ? _domainController.text.trim() : widget.domain,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface),
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
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
      child: Row(
        children: [
          if (_currentStep > 0)
            Expanded(
              child: TextButton(
                onPressed: _prevStep,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text('Back', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
              ),
            ),
          if (_currentStep > 0) const SizedBox(width: 12),
          if (_currentStep < 3)
            Expanded(
              child: ElevatedButton(
                onPressed: _canProceed ? _nextStep : null,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
                  disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: Text(
                  _currentStep == 2 ? 'Review' : 'Continue',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            )
          else
            Expanded(
              child: ElevatedButton(
                onPressed: _isLoading ? null : _createSpace,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
                  disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: _isLoading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Create Space', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.5)),
              ),
            ),
          if (_currentStep < 3) ...[
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text('Cancel', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
            ),
          ],
        ],
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
      style: TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w500),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        labelStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        prefixIcon: Icon(icon, color: errorText != null ? theme.colorScheme.error : theme.colorScheme.primary),
        helperText: helperText,
        helperMaxLines: 2,
        errorText: errorText,
        suffixIcon: suffix,
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: errorText != null ? theme.colorScheme.error : theme.colorScheme.outline.withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: errorText != null ? theme.colorScheme.error : theme.colorScheme.primary, width: 2),
        ),
      ),
    );
  }
}
