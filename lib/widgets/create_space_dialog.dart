import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
  final _nodeController = TextEditingController();
  final _descController = TextEditingController();
  late final TextEditingController _domainController;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    final d = widget.domain;
    // Default to pubsub.domain.com — the standard PubSub service location.
    // If the server uses the domain itself as pubsub host, the user can change it.
    _domainController = TextEditingController(
      text: d.contains('.') ? 'pubsub.$d' : d,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nodeController.dispose();
    _descController.dispose();
    _domainController.dispose();
    super.dispose();
  }

  bool _showNameError = false;

  Future<void> _createSpace() async {
    final name = _nameController.text.trim();
    final node = _nodeController.text.trim().isNotEmpty
        ? _nodeController.text.trim()
        : 'space_${DateTime.now().millisecondsSinceEpoch}';
    final targetDomain = _domainController.text.trim();

    if (name.isEmpty) {
      setState(() => _showNameError = true);
      return;
    }
    if (targetDomain.isEmpty) return;

    setState(() { _isLoading = true; _showNameError = false; });

    final errorMessage = await widget.spacesService.createSpace(
      targetDomain,
      node,
      name,
      description: _descController.text.trim(),
    );

    setState(() => _isLoading = false);

    if (errorMessage == null) {
      if (mounted) {
        Provider.of<AuthService>(context, listen: false).joinPersistedSpace(targetDomain, node, name);
        Navigator.pop(context);
      }
      widget.onSuccess();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            duration: const Duration(seconds: 5),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
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
                    'Spaces allow you to group multiple rooms and communities together.',
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
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _descController,
                    label: 'Description (Optional)',
                    icon: Icons.description_rounded,
                    theme: theme,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _domainController,
                    label: 'PubSub Domain',
                    icon: Icons.dns_rounded,
                    theme: theme,
                    helperText: 'Usually pubsub.yourdomain.com — check with your server admin',
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _nodeController,
                    label: 'Node ID (Optional)',
                    icon: Icons.code_rounded,
                    theme: theme,
                  ),
                  const SizedBox(height: 32),
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
                            onPressed: _createSpace,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              backgroundColor: theme.colorScheme.primary,
                              foregroundColor: theme.colorScheme.onPrimary,
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
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: TextStyle(
        color: theme.colorScheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        prefixIcon: Icon(icon, color: errorText != null ? theme.colorScheme.error : theme.colorScheme.primary),
        helperText: helperText,
        helperMaxLines: 2,
        errorText: errorText,
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
