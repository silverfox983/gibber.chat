import 'package:flutter/material.dart';

import '../models/transport_models.dart';
import '../services/transport_service.dart';
import 'glassmorphic_container.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showTransportRegistrationDialog({
  required BuildContext context,
  required TransportService transportService,
  required String gatewayJid,
  required String gatewayName,
}) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => Center(
      child: GlassMorphicContainer(
        width: 120,
        height: 120,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(strokeWidth: 3),
            const SizedBox(height: 16),
            Text('Probing...', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    ),
  );

  TransportRegistrationForm? form;
  try {
    form = await transportService.fetchRegistrationForm(gatewayJid);
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to fetch form: $e')),
      );
    }
    return;
  }

  if (context.mounted) Navigator.pop(context); // close loading

  if (form == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No registration form available.')),
      );
    }
    return;
  }

  if (context.mounted) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Registration',
      pageBuilder: (context, anim1, anim2) => Center(
        child: TransportRegistrationDialog(
          gatewayJid: gatewayJid,
          gatewayName: gatewayName,
          form: form!,
          transportService: transportService,
        ),
      ),
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (ctx, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
            child: child,
          ),
        );
      },
    );
  }
}

class TransportRegistrationDialog extends StatefulWidget {
  final String gatewayJid;
  final String gatewayName;
  final TransportRegistrationForm form;
  final TransportService transportService;

  const TransportRegistrationDialog({
    super.key,
    required this.gatewayJid,
    required this.gatewayName,
    required this.form,
    required this.transportService,
  });

  @override
  State<TransportRegistrationDialog> createState() =>
      _TransportRegistrationDialogState();
}

class _TransportRegistrationDialogState extends State<TransportRegistrationDialog> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _formData = {};
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    for (var field in widget.form.fields) {
      if (field.type == 'boolean') {
        _formData[field.varName] = (field.value == '1' || field.value == 'true') ? '1' : '0';
      } else if (field.type == 'list-single' || field.type == 'list-multi') {
        _formData[field.varName] = field.value ?? (field.options?.isNotEmpty == true ? field.options!.first.value : '');
      } else {
        _formData[field.varName] = field.value ?? '';
        _controllers[field.varName] = TextEditingController(text: field.value);
        _controllers[field.varName]!.addListener(() {
          _formData[field.varName] = _controllers[field.varName]!.text;
        });
      }
    }
  }

  @override
  void dispose() {
    for (var c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRegistered = widget.form.isRegistered;

    return Material(
      color: Colors.transparent,
      child: GlassMorphicContainer(
        width: MediaQuery.of(context).size.width * 0.85,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('GATEWAY REGISTRATION',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.5,
                                color: theme.colorScheme.primary)),
                        const SizedBox(height: 4),
                        Text(widget.gatewayName,
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w900)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (isRegistered)
                _buildRegisteredView(theme)
              else
                _buildFormView(theme),
              const SizedBox(height: 32),
              _buildActions(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRegisteredView(ThemeData theme) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_rounded, color: Colors.green, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Active Connection',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text('You are registered with this service.',
                        style: TextStyle(
                            fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'To use this transport, you can start searching for contacts or rooms from this provider.',
          style: TextStyle(
              fontSize: 13, height: 1.5, color: theme.colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildFormView(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.form.instructions != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              widget.form.instructions!,
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (widget.form.oobUrl != null) ...[
          Center(
            child: FilledButton.icon(
              onPressed: () async {
                final uri = Uri.parse(widget.form.oobUrl!);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                } else {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open link.')));
                }
              },
              icon: const Icon(Icons.open_in_browser_rounded),
              label: Text('Authenticate via Browser', style: TextStyle(fontWeight: FontWeight.bold)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('After authenticating in your browser, press "Complete Registration" below.',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
          const SizedBox(height: 16),
        ],
        ...widget.form.fields.map((field) {
          if (field.type == 'hidden') return const SizedBox.shrink();

          if (field.type == 'boolean') {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SwitchListTile(
                  title: Text(field.label ?? field.varName, style: TextStyle(fontSize: 14)),
                  value: _formData[field.varName] == '1',
                  onChanged: (val) => setState(() => _formData[field.varName] = val ? '1' : '0'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
            );
          }

          if (field.type == 'list-single' && field.options != null && field.options!.isNotEmpty) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: DropdownButtonFormField<String>(
                initialValue: _formData[field.varName]!.isNotEmpty ? _formData[field.varName] : field.options!.first.value,
                decoration: InputDecoration(
                  labelText: field.label ?? field.varName,
                  labelStyle: TextStyle(fontSize: 14),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                ),
                items: field.options!.map((opt) => DropdownMenuItem(value: opt.value, child: Text(opt.label))).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _formData[field.varName] = val);
                },
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: TextField(
              controller: _controllers[field.varName],
              obscureText: field.type == 'text-private' || field.varName.toLowerCase().contains('password'),
              decoration: InputDecoration(
                labelText: field.label ?? field.varName,
                labelStyle: TextStyle(fontSize: 14),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildActions(ThemeData theme) {
    final isRegistered = widget.form.isRegistered;

    return Row(
      children: [
        if (isRegistered)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isSubmitting
                  ? null
                  : () async {
                      setState(() => _isSubmitting = true);
                      final success = await widget.transportService.unregister(
                        widget.gatewayJid,
                      );
                      if (mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              success
                                  ? 'Successfully unregistered.'
                                  : 'Failed to unregister.',
                            ),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
              icon: _isSubmitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.no_accounts_rounded, size: 18),
              label: const Text('UNREGISTER'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          )
        else
          Expanded(
            child: FilledButton(
              onPressed: _isSubmitting
                  ? null
                  : () async {
                      setState(() => _isSubmitting = true);
                      final success = await widget.transportService
                          .submitRegistration(widget.gatewayJid, _formData, formType: widget.form.formType);
                      if (mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              success
                                  ? 'Registration complete!'
                                  : 'Registration failed. Check your details.',
                            ),
                            behavior: SnackBarBehavior.floating,
                            backgroundColor: success ? Colors.green : null,
                          ),
                        );
                      }
                    },
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(widget.form.oobUrl != null ? 'COMPLETE REGISTRATION' : 'CONNECT SERVICE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
            ),
          ),
      ],
    );
  }
}
