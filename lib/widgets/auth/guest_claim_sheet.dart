import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_models.dart';
import '../../providers/chat_provider.dart';
import '../../services/auth_service.dart';
import '../../services/backend_config.dart';
import '../../services/database_service.dart';
import '../../services/registration_service.dart';
import '../../services/visitor_service.dart';

/// Opens the claim flow when this browser is running on an auto-created
/// guest account. Returns true when the claim succeeded.
Future<bool?> showGuestClaimSheet(BuildContext context) async {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const GuestClaimSheet(),
  );
}

class GuestClaimSheet extends StatefulWidget {
  const GuestClaimSheet({super.key});

  @override
  State<GuestClaimSheet> createState() => _GuestClaimSheetState();
}

class _GuestClaimSheetState extends State<GuestClaimSheet> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _guestJid;
  String? _error;
  bool _checking = false;
  bool _claiming = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final jid = await VisitorService().guestJid();
    if (!mounted) return;
    setState(() {
      _guestJid = jid;
      _checking = false;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _checking = true;
      _error = null;
    });

    // Capture providers before the first await.
    final auth = context.read<AuthService>();
    final chat = context.read<ChatProvider>();

    final availability = await RegistrationService.checkUsernameAvailable(
      apiUrl: BackendConfig().apiUrl,
      username: _username.text.trim(),
    );
    if (mounted && availability == false) {
      setState(() {
        _checking = false;
        _error = 'That name is already taken.';
      });
      return;
    }

    // Capture what should follow the account across the claim.
    final contacts = List<Contact>.from(chat.contacts);
    final rooms = chat.conversations.where((c) => c.isGroup).map((c) => c.id).toList();

    if (!mounted) return;
    setState(() {
      _checking = false;
      _claiming = true;
    });

    final result = await VisitorService().claimAccount(
      authService: auth,
      databaseService: DatabaseService(),
      newUsername: _username.text.trim().toLowerCase(),
      newPassword: _password.text,
      captureContacts: contacts,
      captureRooms: rooms,
    );
    if (!mounted) return;

    if (result.ok && result.account != null) {
      await chat.reloadFromDb(auth);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          'Welcome, ${result.account!.username}! '
          '${result.migratedItems > 0 ? '${result.migratedItems} items moved. ' : ''}'
          'Keep this password — it is your real account now.',
        ),
      ));
      return;
    }

    setState(() {
      _claiming = false;
      _error = result.error ?? 'Claim failed. Try another name.';
    });
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final primary = theme.colorScheme.primary;

    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 14, 20, 20 + media.viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: primary.withValues(alpha: 0.15),
                child: Icon(Icons.badge_rounded, color: primary, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Claim your account',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _guestJid == null
                ? 'Your current session will be upgraded to a permanent account.'
                : 'You are chatting as a guest ($_guestJid). Pick a name you '
                    'want to keep — your chats, contacts and rooms move over.',
            style: TextStyle(fontSize: 12.5, height: 1.45, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                TextField(
                  controller: _username,
                  enabled: !_claiming && !_checking,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Username',
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _password,
                  enabled: !_claiming && !_checking,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Password (min 8 chars, letters + numbers)',
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 18),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(_error!,
                        style: TextStyle(fontSize: 12.5, color: theme.colorScheme.error, height: 1.4)),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: _claiming || _checking ? null : _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: (_claiming || _checking)
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('CLAIM ACCOUNT', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                ),
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    'Gateway networks (WhatsApp, Discord...) must be re-linked '
                    'once under your new name.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}