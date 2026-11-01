import 'dart:async';
import 'package:flutter/services.dart' show Clipboard;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/transport_models.dart';
import '../../providers/chat_provider.dart';
import '../../services/auth_service.dart';
import '../../services/gateway_protocols.dart';
import '../../services/transport_service.dart';

/// Per-protocol gateway sign-in sheet.
///
/// Steps by network:
///  - form:    XEP-0004/0077 registration form (Discord token, Matrix
///             credentials, WhatsApp "continue" form...), re-rendered in a
///             loop when the gateway answers a submit with a follow-up form.
///  - pairing: WhatsApp QR-code pairing: the QR arrives as an oob attachment
///             message from the gateway component and is rendered live.
///  - chat:    gateways that only support adhoc/chat commands (Telegram):
///             instructions + a live log of the gateway's chat replies.
///  - channels: Discord guild channels discovered via disco#items; tapping
///             joins the channel as a MUC.
///  - done:    registered; gateway contacts appear in the contact list via
///             roster pushes (XEP-0356 privileges) automatically.
Future<bool?> showGatewayRegistrationSheet({
  required BuildContext context,
  required TransportService transportService,
  required String gatewayJid,
  required String gatewayName,
}) async {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => GatewayRegistrationSheet(
      transportService: transportService,
      gatewayJid: gatewayJid,
      gatewayName: gatewayName,
    ),
  );
}

enum GatewayRegStep { loading, form, pairing, chatFlow, channels, done }

class GatewayRegistrationSheet extends StatefulWidget {
  final TransportService transportService;
  final String gatewayJid;
  final String gatewayName;

  const GatewayRegistrationSheet({
    super.key,
    required this.transportService,
    required this.gatewayJid,
    required this.gatewayName,
  });

  @override
  State<GatewayRegistrationSheet> createState() => _GatewayRegistrationSheetState();
}

class _GatewayRegistrationSheetState extends State<GatewayRegistrationSheet> {
  GatewayRegStep _step = GatewayRegStep.loading;

  TransportRegistrationForm? _form;
  String? _formError;

  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _formData = {};
  bool _submitting = false;

  final List<String> _pairingLog = [];
  String? _qrUrl;
  StreamSubscription<GatewayPairingEvent>? _pairingSub;

  List<GatewayChatItem> _chats = [];
  bool _loadingChats = false;
  final Map<String, bool> _joiningChats = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    TransportRegistrationForm? form;
    String? error;
    try {
      form = await widget.transportService.fetchRegistrationForm(widget.gatewayJid);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;

    if (error != null) {
      if (error.contains('adhoc')) {
        // Gateway only accepts chat/adhoc-driven flows (Telegram et al).
        setState(() => _step = GatewayRegStep.chatFlow);
        return;
      }
      setState(() { _formError = error; _step = GatewayRegStep.form; });
      return;
    }
    _form = form;
    if (form != null && form.isRegistered) {
      if (form.isEmptyForm && !_hasFillableFields(form)) {
        // Registered + an instruction-only form: nothing to do here.
        setState(() => _step = GatewayRegStep.done);
        return;
      }
    }
    if (form == null) {
      // No XEP-0077 form: adhoc/chat-command gateway (Telegram et al).
      setState(() => _step = GatewayRegStep.chatFlow);
      return;
    }
    if (_hasFillableFields(form)) {
      _initFormControllers(form);
      setState(() => _step = GatewayRegStep.form);
    } else {
      // Instruction-only form (slidge WhatsApp): submitting it starts pairing.
      setState(() => _step = GatewayRegStep.form);
    }
  }

  bool _hasFillableFields(TransportRegistrationForm? form) =>
      form != null && form.fields.any((f) => f.type != 'hidden' && f.type != 'fixed');

  void _initFormControllers(TransportRegistrationForm form) {
    for (var field in form.fields) {
      if (field.type == 'boolean') {
        _formData[field.varName] = (field.value == '1' || field.value == 'true') ? '1' : '0';
      } else if (field.type == 'list-single' || field.type == 'list-multi') {
        _formData[field.varName] = field.value ?? (field.options?.isNotEmpty == true ? field.options!.first.value : '');
      } else if (!_controllers.containsKey(field.varName)) {
        _formData[field.varName] = field.value ?? '';
        _controllers[field.varName] = TextEditingController(text: field.value ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (var c in _controllers.values) {
      c.dispose();
    }
    _pairingSub?.cancel();
    widget.transportService.stopPairing(widget.gatewayJid);
    super.dispose();
  }

  String get _protocol =>
      GatewayProtocols.protocolForJid(widget.gatewayJid, ownDomain: _ownDomain) ?? 'Gateway';

  String get _ownDomain {
    final auth = Provider.of<AuthService>(context, listen: false);
    final conn = auth.activeXmppConnection;
    return conn?.fullJid.domain ?? '';
  }

  ChatProvider get _chatProvider => Provider.of<ChatProvider>(context, listen: false);

  Future<void> _submit() async {
    if (_submitting || _form == null) return;
    setState(() { _submitting = true; _formError = null; });
    final result = await widget.transportService.submitRegistration(
      widget.gatewayJid,
      _formData,
      formType: _form!.formType,
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (!result.success) {
      setState(() => _formError = result.errorText ?? 'Registration failed.');
      return;
    }

    // Persisted + contact import kicked off by the service.
    if (result.nextForm != null) {
      _form = result.nextForm;
      _form = TransportRegistrationForm(
        isRegistered: false,
        instructions: 'Almost there â€” the gateway needs one more step.',
        formType: result.nextForm!.formType,
        fields: result.nextForm!.fields,
      );
      setState(() => _formError = null);
      return;
    }

    await _afterRegistration();
  }

  Future<void> _afterRegistration() async {
    switch (_protocol) {
      case 'WhatsApp':
        _startPairingListen();
        setState(() => _step = GatewayRegStep.pairing);
      case 'Discord':
        setState(() => _step = GatewayRegStep.channels);
        await _loadChats();
      default:
        setState(() => _step = GatewayRegStep.done);
    }
  }

  void _startPairingListen() {
    setState(() {
      _qrUrl = null;
      _pairingLog.clear();
    });
    _pairingSub?.cancel();
    _pairingSub = widget.transportService
        .listenPairing(widget.gatewayJid)
        .listen((event) {
      if (!mounted) return;
      setState(() {
        if (event.oobUrl != null) {
          _qrUrl = _rewriteQrUrl(event.oobUrl!);
        }
        if (event.text != null && event.text!.isNotEmpty) {
          _pairingLog.insert(0, event.text!);
        }
        if (event.isSuccess) {
          _step = GatewayRegStep.done;
        }
        if (event.kind == 'error') {
          _formError = event.text;
        }
      });
    });
  }

  /// The gateway advertises internal http:// file-share urls; browsers need
  /// the same-origin /upload proxy.
  String _rewriteQrUrl(String url) {
    final idx = url.indexOf('/upload/');
    if (idx == -1) return url;
    return url.substring(idx);
  }

  Future<void> _retryPairing() async {
    setState(() { _formError = null; });
    final result = await widget.transportService.submitRegistration(
      widget.gatewayJid,
      const {},
      formType: _form?.formType,
    );
    if (!mounted) return;
    if (result.success) {
      _startPairingListen();
    } else {
      setState(() => _formError = result.errorText ?? 'Could not restart pairing.');
    }
  }

  Future<void> _openGatewayChat() async {
    _pairingSub?.cancel();
    // The gateway conversation becomes a chat entry point (its messages —
    // pairing QRs, codes, status — render right in the chat).
    _chatProvider.setActiveConversation(widget.gatewayJid);
    if (!mounted) return;
    Navigator.of(context).pop(true);
    context.go('/app');
  }

  Future<void> _loadChats() async {
    setState(() => _loadingChats = true);
    final chats = await widget.transportService.fetchComponentChats(widget.gatewayJid);
    if (!mounted) return;
    setState(() { _chats = chats; _loadingChats = false; });
  }

  Future<void> _joinChat(GatewayChatItem chat) async {
    final auth = Provider.of<AuthService>(context, listen: false);
    setState(() => _joiningChats[chat.jid] = true);
    final nick = auth.getResolvedNickname(null);
    final error = await auth.joinXmppRoom(chat.jid, nick);
    if (!mounted) return;
    setState(() => _joiningChats[chat.jid] = false);
    if (error != null) {
      setState(() => _formError = 'Could not join ${chat.name}: $error');
      return;
    }
    _chatProvider.setActiveConversation(chat.jid);
    _chatProvider.setConversationFallbackName(chat.jid, chat.name);
    if (!mounted) return;
    Navigator.of(context).pop(true);
    context.go('/app');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final meta = GatewayProtocols.metaByProtocol[_protocol];
    final accent = meta?.color ?? theme.colorScheme.primary;

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
              if (meta != null)
                CircleAvatar(
                  radius: 18,
                  backgroundColor: accent.withValues(alpha: 0.15),
                  child: Icon(meta.icon, color: accent, size: 20),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.gatewayName,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 42),
            child: Text(
              'Bridged on your server: after signing in, your chats and '
              'contacts from this network appear in Gibber automatically.',
              style: TextStyle(fontSize: 12, height: 1.4, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(child: _buildStep(theme)),
        ],
      ),
    );
  }

  Widget _buildStep(ThemeData theme) {
    switch (_step) {
      case GatewayRegStep.loading:
        return const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        );
      case GatewayRegStep.form:
        return _buildFormStep(theme);
      case GatewayRegStep.pairing:
        return _buildPairingStep(theme);
      case GatewayRegStep.chatFlow:
        return _buildChatFlowStep(theme);
      case GatewayRegStep.channels:
        return _buildChannelsStep(theme);
      case GatewayRegStep.done:
        return _buildDoneStep(theme);
    }
  }

  Widget _buildErrorBanner(ThemeData theme, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: theme.colorScheme.error, height: 1.4)),
    );
  }

  Widget _buildFormStep(ThemeData theme) {
    final form = _form;
    if (form == null) {
      return Column(children: [
        if (_formError != null) _buildErrorBanner(theme, _formError!),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () { Navigator.of(context).pop(false); },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Back to networks'),
        ),
      ]);
    }
    final isEmptyForm = !_hasFillableFields(form);
    final isWhatsapp = _protocol == 'WhatsApp';

    return ListView(
      shrinkWrap: true,
      children: [
        if (form.instructions != null && form.instructions!.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(form.instructions!, style: const TextStyle(fontSize: 12, height: 1.45)),
          ),
        if (isEmptyForm && isWhatsapp) ..._buildWhatsappIntro(theme),
        const SizedBox(height: 16),
        if (isEmptyForm)
          const SizedBox.shrink()
        else
          ..._renderFields(theme),
        if (_formError != null) ...[
          const SizedBox(height: 12),
          _buildErrorBanner(theme, _formError!),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(
                  isEmptyForm ? _protocol == 'WhatsApp' ? 'START PAIRING' : 'CONTINUE' : 'CONNECT',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                ),
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton.icon(
            onPressed: _openGatewayChat,
            icon: const Icon(Icons.chat_rounded, size: 16),
            label: Text('Pair via gateway chat', style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant)),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildWhatsappIntro(ThemeData theme) {
    return [
      const SizedBox(height: 16),
      Row(
        children: [
          Icon(Icons.qr_code_rounded, size: 28, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'After continuing, point your phone at the QR code shown here. '
              'WhatsApp â†’ Settings â†’ Linked devices â†’ Link a device.',
              style: TextStyle(fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _renderFields(ThemeData theme) {
    final form = _form!;
    return form.fields.map((field) {
      if (field.type == 'hidden' || field.type == 'fixed') return const SizedBox.shrink();
      if (field.type == 'boolean') {
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(field.label ?? field.varName, style: const TextStyle(fontSize: 13.5)),
            value: _formData[field.varName] == '1',
            onChanged: (val) => setState(() => _formData[field.varName] = val ? '1' : '0'),
          ),
        );
      }
      if (field.type == 'list-single' && field.options != null && field.options!.isNotEmpty) {
        final current = _formData[field.varName]!;
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: DropdownButtonFormField<String>(
            initialValue: current.isNotEmpty ? current : field.options!.first.value,
            decoration: InputDecoration(
              labelText: field.label ?? field.varName,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            items: field.options!.map((opt) => DropdownMenuItem(value: opt.value, child: Text(opt.label))).toList(),
            onChanged: (val) {
              if (val != null) setState(() => _formData[field.varName] = val);
            },
          ),
        );
      }

      final isPhone = field.varName.toLowerCase().contains('phone');
      final isToken = field.varName.toLowerCase() == 'token';
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controllers[field.varName],
              keyboardType: isPhone ? TextInputType.phone : TextInputType.text,
              obscureText: field.type == 'text-private' ||
                  field.varName.toLowerCase().contains('password') ||
                  isToken,
              decoration: InputDecoration(
                labelText: field.label ?? field.varName,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                suffixIcon: isToken
                    ? IconButton(
                        tooltip: 'Paste from clipboard',
                        icon: const Icon(Icons.paste_rounded, size: 18),
                        onPressed: () async {
                          final data = await Clipboard.getData(Clipboard.kTextPlain);
                          final text = data?.text;
                          if (!mounted) return;
                          if (text != null && text.trim().isNotEmpty) {
                            final controller = _controllers[field.varName]!;
                            controller.text = text.trim();
                            setState(() => _formData[field.varName] = controller.text);
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Clipboard is empty')),
                            );
                          }
                        },
                      )
                    : null,
              ),
            ),
            if (isToken)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 2),
                child: Text(
                  'Paste your Discord token (see instructions above for how to get one).',
                  style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      );
    }).toList();
  }

  Widget _buildPairingStep(ThemeData theme) {
    return ListView(
      shrinkWrap: true,
      children: [
        if (_qrUrl != null)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                _qrUrl!,
                height: 240,
                fit: BoxFit.contain,
                loadingBuilder: (c, w, p) => const SizedBox(
                  height: 100,
                  child: Center(child: CircularProgressIndicator()),
                ),
                errorBuilder: (c, e, st) => Column(
                  children: [
                    const Icon(Icons.image_not_supported_rounded, size: 40, color: Colors.grey),
                    Text('Could not load the QR image.', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          )
        else ...[
          const Center(child: Padding(
            padding: EdgeInsets.all(18),
            child: CircularProgressIndicator(),
          )),
          const SizedBox(height: 8),
          const Center(child: Text('Waiting for the pairing QR from the gatewayâ€¦',
              style: TextStyle(fontSize: 12.5))),
        ],
        const SizedBox(height: 12),
        if (_pairingLog.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _pairingLog.take(3).join('\n'),
              style: TextStyle(fontSize: 11.5, height: 1.4, color: theme.colorScheme.onSurfaceVariant),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (_formError != null) ...[
          const SizedBox(height: 12),
          _buildErrorBanner(theme, _formError!),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _retryPairing,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('New QR code'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _openGatewayChat,
                icon: const Icon(Icons.chat_rounded, size: 16),
                label: const Text('Open chat'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Keep this open. Pairing completes on its own once scanned â€” '
            'your contacts appear automatically.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _buildChatFlowStep(ThemeData theme) {
    return ListView(
      shrinkWrap: true,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _protocol == 'Telegram'
                ? 'This gateway is driven by chat commands. Open the gateway '
                    'chat and send your phone number (in international format, '
                    'e.g. +15551234567). Telegram sends the login code; reply '
                    'with it in the same chat.'
                : 'This gateway is driven by chat commands. Open the gateway '
                    'chat and type "login" to get started.',
            style: const TextStyle(fontSize: 12.5, height: 1.45),
          ),
        ),
        if (_formError != null) ...[
          const SizedBox(height: 12),
          _buildErrorBanner(theme, _formError!),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _openGatewayChat,
          icon: const Icon(Icons.chat_rounded),
          label: const Text('Open gateway chat'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 10),
        Center(child: Text(
          'The gateway replies and the code-request forms appear right in the '
          'chat. Contacts sync over automatically.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant, height: 1.4),
        )),
      ],
    );
  }

  Widget _buildChannelsStep(ThemeData theme) {
    return ListView(
      shrinkWrap: true,
      children: [
        Row(
          children: [
            Expanded(child: Text(
              _chats.isEmpty ? 'No channels synced yet.' : 'Channels found on your Discord â€” tap to open.',
              style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurfaceVariant),
            )),
            IconButton(
              onPressed: _loadingChats ? null : _loadChats,
              icon: _loadingChats
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final chat in _chats.take(40))
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(Icons.tag_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
            title: Text(chat.name, style: const TextStyle(fontSize: 13.5)),
            subtitle: Text(chat.jid, style: const TextStyle(fontSize: 10.5), maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: (_joiningChats[chat.jid] ?? false)
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.arrow_forward_rounded, size: 15),
            onTap: (_joiningChats[chat.jid] ?? false) ? null : () => _joinChat(chat),
          ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: const Text('DONE', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        ),
      ],
    );
  }

  Widget _buildDoneStep(ThemeData theme) {
    return ListView(
      shrinkWrap: true,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.green.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_rounded, color: Colors.green, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '$_protocol connected. Contacts and chats from this network '
                  'appear in Gibber automatically as they sync.',
                  style: const TextStyle(fontSize: 12.5, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_protocol == 'Discord') ...[
          OutlinedButton.icon(
            onPressed: () { setState(() => _step = GatewayRegStep.channels); },
            icon: const Icon(Icons.tag_rounded, size: 16),
            label: const Text('Browse channels'),
          ),
          const SizedBox(height: 8),
        ],
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: const Text('DONE', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        ),
      ],
    );
  }
}