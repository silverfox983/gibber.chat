import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/space_models.dart';
import '../services/spaces_service.dart';
import '../services/auth_service.dart';

class JoinSpaceDialog extends StatefulWidget {
  final SpacesService spacesService;
  final String currentUserDomain;
  final VoidCallback? onSuccess;

  const JoinSpaceDialog({
    super.key,
    required this.spacesService,
    required this.currentUserDomain,
    this.onSuccess,
  });

  @override
  State<JoinSpaceDialog> createState() => _JoinSpaceDialogState();
}

class _JoinSpaceDialogState extends State<JoinSpaceDialog> {
  final _keyController = TextEditingController();
  bool _isLoading = false;
  bool _isParsing = false;
  String? _errorText;

  String? _parsedDomain;
  String? _parsedNode;
  SpaceNode? _discoveredSpace;

  @override
  void initState() {
    super.initState();
    _autoDetectClipboard();
  }

  Future<void> _autoDetectClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) return;
      if (text.startsWith('xmpp:') || RegExp(r'^[^@]+@[^/]+/.+$').hasMatch(text) || (text.contains('/') && text.split('/').length == 2 && text.split('/').every((p) => p.contains('.')))) {
        _keyController.text = text;
        _parseKey(text);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _parseKey(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _parsedDomain = null;
        _parsedNode = null;
        _discoveredSpace = null;
        _errorText = null;
      });
      return;
    }

    setState(() { _isParsing = true; _errorText = null; });

    try {
      String domain;
      String node;

      if (trimmed.startsWith('xmpp:')) {
        final uri = trimmed.replaceFirst('xmpp:', '');
        final parts = uri.split('?;node=');
        if (parts.length == 2) {
          domain = parts[0];
          node = parts[1];
        } else {
          setState(() { _errorText = 'Invalid XMPP URI format. Expected: xmpp:domain?;node=key'; _isParsing = false; });
          return;
        }
      } else if (trimmed.contains('/') && !trimmed.contains('@')) {
        final parts = trimmed.split('/');
        if (parts.length == 2) {
          domain = parts[0];
          node = parts[1];
        } else {
          setState(() { _errorText = 'Invalid format. Use: domain/node'; _isParsing = false; });
          return;
        }
      } else if (trimmed.contains('@')) {
        final atIdx = trimmed.indexOf('@');
        node = trimmed.substring(0, atIdx);
        domain = trimmed.substring(atIdx + 1);
      } else if (trimmed.contains('/') && trimmed.split('/').length == 2) {
        final parts = trimmed.split('/');
        domain = parts[0];
        node = parts[1];
      } else {
        setState(() { _errorText = 'Unrecognized format. Paste an invite key (xmpp:domain?;node=..., domain/node, or node@domain).'; _isParsing = false; });
        return;
      }

      if (domain.isEmpty || node.isEmpty) {
        setState(() { _errorText = 'Domain and node cannot be empty.'; _isParsing = false; });
        return;
      }

      setState(() { _parsedDomain = domain; _parsedNode = node; });

      // Try to discover the space metadata
      final space = SpaceNode(domain: domain, node: node, name: node);
      final details = await widget.spacesService.fetchSpaceDetails(space).timeout(
        const Duration(seconds: 8),
        onTimeout: () => space,
      );
      if (mounted) {
        setState(() { _discoveredSpace = details; _isParsing = false; });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _errorText = 'Could not parse key: $e'; _isParsing = false; });
      }
    }
  }

  Future<void> _joinSpace() async {
    if (_parsedDomain == null || _parsedNode == null) return;

    setState(() { _isLoading = true; _errorText = null; });

    try {
      final auth = Provider.of<AuthService>(context, listen: false);
      final myJid = auth.activeXmppConnection?.fullJid.userAtDomain ?? '';
      if (myJid.isEmpty) {
        setState(() { _errorText = 'Not connected to XMPP server.'; _isLoading = false; });
        return;
      }

      final success = await widget.spacesService.subscribeToSpace(
        _parsedDomain!,
        _parsedNode!,
        myJid,
        spaceType: 'leaf',
      );

      if (success) {
        final spaceName = _discoveredSpace?.name ?? _parsedNode!;
        auth.joinPersistedSpace(_parsedDomain!, _parsedNode!, spaceName);

        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Joined "$spaceName"!'),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 3),
              action: SnackBarAction(
                label: 'OPEN',
                textColor: Colors.white,
                onPressed: () {
                  final space = SpaceNode(
                    domain: _parsedDomain!,
                    node: _parsedNode!,
                    name: spaceName,
                    isSubscribed: true,
                  );
                  context.pushNamed('spaceDetail', extra: {
                    'space': space,
                    'spacesService': widget.spacesService,
                  });
                },
              ),
            ),
          );
          widget.onSuccess?.call();
        }
      } else {
        if (mounted) {
          setState(() {
            _errorText = 'Join request sent — waiting for approval, or the server rejected the request.';
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() { _errorText = 'Error: $e'; _isLoading = false; });
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
            width: 440,
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
                  Icon(Icons.login_rounded, size: 48, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Join a Space',
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
                    'Paste an invite key to join an existing space.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  _buildKeyField(theme),
                  const SizedBox(height: 16),
                  if (_isParsing)
                    const Center(child: Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )),
                  if (_discoveredSpace != null && !_isParsing) _buildSpacePreview(theme),
                  if (_errorText != null && !_isParsing) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded, size: 16, color: theme.colorScheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorText!,
                              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: Text('Cancel', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: (_parsedDomain != null && _parsedNode != null && !_isLoading)
                              ? _joinSpace
                              : null,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.onPrimary,
                            disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
                            disabledForegroundColor: theme.colorScheme.onSurfaceVariant,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            elevation: 0,
                          ),
                          child: _isLoading
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('Join', style: TextStyle(fontWeight: FontWeight.w900)),
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

  Widget _buildKeyField(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _keyController,
          style: TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w500),
          onChanged: (v) => _parseKey(v),
          decoration: InputDecoration(
            labelText: 'Invite Key',
            hintText: 'xmpp:spaces.example.com?;node=abc123',
            labelStyle: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            prefixIcon: Icon(Icons.vpn_key_rounded, color: theme.colorScheme.primary),
            suffixIcon: IconButton(
              icon: Icon(Icons.paste_rounded, color: theme.colorScheme.onSurfaceVariant),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  _keyController.text = data!.text!;
                  _parseKey(data.text!);
                }
              },
            ),
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Paste an XMPP URI, domain/node, or node@domain',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSpacePreview(ThemeData theme) {
    final space = _discoveredSpace!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary.withValues(alpha: 0.2),
            ),
            child: space.avatarUrl != null
                ? ClipOval(child: Image.network(space.avatarUrl!, width: 48, height: 48, fit: BoxFit.cover))
                : Icon(Icons.workspaces_rounded, size: 24, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  space.name,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: theme.colorScheme.onSurface),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (space.description != null && space.description!.isNotEmpty)
                  Text(
                    space.description!,
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.dns_rounded, size: 12, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(_parsedDomain!, style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: theme.colorScheme.onSurfaceVariant)),
                    if (space.accessModel != null) ...[
                      const SizedBox(width: 10),
                      Icon(
                        space.accessModel == 'open' ? Icons.public_rounded : Icons.lock_rounded,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(space.accessModel!, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
