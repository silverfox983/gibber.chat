import 'dart:ui';
import 'package:flutter/material.dart';
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
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _slugController = TextEditingController();
  late final TextEditingController _domainController;
  bool _isLoading = false;
  bool _domainValid = false;
  bool _domainChecked = false;
  String? _domainError;
  String _accessModel = 'open';
  String _publishModel = 'publishers';

  @override
  void initState() {
    super.initState();
    final d = widget.domain;
    _domainController = TextEditingController(
      text: d.contains('.') ? 'pubsub.$d' : d,
    );
    _nameController.addListener(_onNameChanged);
    _validateDomain();
  }

  void _onNameChanged() {
    final name = _nameController.text.trim();
    if (name.isNotEmpty && _slugController.text.isEmpty) {
      final slug = name.toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9\s\-]'), '')
          .replaceAll(RegExp(r'\s+'), '-')
          .replaceAll(RegExp(r'-+'), '-')
          .replaceAll(RegExp(r'^-+|-+$'), '');
      _slugController.text = slug;
    }
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    _descController.dispose();
    _slugController.dispose();
    _domainController.dispose();
    super.dispose();
  }

  Future<void> _validateDomain() async {
    final domain = _domainController.text.trim();
    if (domain.isEmpty || !domain.contains('.')) {
      setState(() { _domainValid = false; _domainChecked = true; _domainError = null; });
      return;
    }
    setState(() { _domainChecked = false; _domainError = null; });
    try {
      await widget.spacesService.discoverAllSpaces(domain).timeout(
        const Duration(seconds: 10),
        onTimeout: () => <SpaceNode>[],
      );
      if (mounted) {
        setState(() {
          _domainChecked = true;
          _domainValid = true;
          _domainError = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _domainChecked = true;
          _domainValid = false;
          _domainError = 'Could not reach "$domain". Check the address.';
        });
      }
    }
  }

  bool _showNameError = false;
  bool _showSlugError = false;

  Future<void> _createSpace() async {
    final name = _nameController.text.trim();
    final slug = _slugController.text.trim().replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final targetDomain = _domainController.text.trim();

    bool hasError = false;
    if (name.isEmpty) { setState(() => _showNameError = true); hasError = true; }
    if (slug.isEmpty) { setState(() => _showSlugError = true); hasError = true; }
    if (!_domainValid) { hasError = true; }
    if (hasError) return;

    setState(() { _isLoading = true; _showNameError = false; _showSlugError = false; });

    final errorMessage = await widget.spacesService.createSpace(
      targetDomain,
      slug,
      name,
      description: _descController.text.trim(),
      accessModel: _accessModel,
      publishModel: _publishModel,
    );

    setState(() => _isLoading = false);

    if (errorMessage == null) {
      if (mounted) {
        Provider.of<AuthService>(context, listen: false).joinPersistedSpace(
          targetDomain,
          slug,
          name,
        );
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Space "$name" created!'),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      }
      widget.onSuccess();
    } else {
      if (mounted) {
        String displayError = errorMessage;
        if (errorMessage.toLowerCase().contains('conflict') ||
            errorMessage.toLowerCase().contains('already exists')) {
          displayError = 'A space with this address already exists. Try a different name.';
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
                    'Create New Space',
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
                    'A space groups rooms and communities under a shared topic.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  _buildTextField(
                    controller: _nameController,
                    label: 'Space Name',
                    icon: Icons.title_rounded,
                    theme: theme,
                    errorText: _showNameError ? 'Space name is required' : null,
                    hintText: 'e.g. Gaming Hub',
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _slugController,
                    label: 'Space Address',
                    icon: Icons.link_rounded,
                    theme: theme,
                    errorText: _showSlugError ? 'Address is required (letters, numbers, hyphens)' : null,
                    hintText: 'my-gaming-hub',
                    helperText: 'Used in URLs. Only letters, numbers, and hyphens.',
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
                    hintText: 'What is this space about?',
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _domainController,
                    label: 'Server',
                    icon: Icons.dns_rounded,
                    theme: theme,
                    helperText: 'The PubSub server where this space will live',
                    errorText: _domainError,
                    suffix: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _domainChecked
                          ? Icon(
                              _domainValid ? Icons.check_circle : Icons.error,
                              color: _domainValid
                                  ? Colors.green
                                  : theme.colorScheme.error,
                              size: 20,
                            )
                          : const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                    ),
                    onChanged: (_) => _validateDomain(),
                  ),
                  const SizedBox(height: 16),
                  _buildDropdown(
                    label: 'Who Can View',
                    icon: Icons.visibility_rounded,
                    theme: theme,
                    value: _accessModel,
                    options: const [
                      DropdownMenuItem(value: 'open', child: Text('Public — Anyone can view')),
                      DropdownMenuItem(value: 'authorize', child: Text('Private — Requires approval')),
                    ],
                    onChanged: (v) => setState(() => _accessModel = v ?? 'open'),
                  ),
                  const SizedBox(height: 16),
                  _buildDropdown(
                    label: 'Who Can Post',
                    icon: Icons.edit_rounded,
                    theme: theme,
                    value: _publishModel,
                    options: const [
                      DropdownMenuItem(value: 'open', child: Text('Anyone — All members can post')),
                      DropdownMenuItem(value: 'publishers', child: Text('Admins Only — Moderated posting')),
                    ],
                    onChanged: (v) => setState(() => _publishModel = v ?? 'publishers'),
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
                              'Create Space',
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
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
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
        suffixIcon: suffix != null ? suffix : null,
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

  Widget _buildDropdown({
    required String label,
    required IconData icon,
    required ThemeData theme,
    required String value,
    required List<DropdownMenuItem<String>> options,
    required void Function(String?) onChanged,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        prefixIcon: Icon(icon, color: theme.colorScheme.primary),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
        ),
      ),
      dropdownColor: theme.colorScheme.surfaceContainerHighest,
      style: TextStyle(
        color: theme.colorScheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      items: options,
      onChanged: onChanged,
    );
  }
}
