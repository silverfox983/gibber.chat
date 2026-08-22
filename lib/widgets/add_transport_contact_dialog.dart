import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../services/transport_service.dart';
import '../models/transport_models.dart';

Future<void> showAddTransportContactDialog({
  required BuildContext context,
  TransportService? transportService,
  List<Map<String, String>> extraGateways = const [],
}) async {
  final authService = Provider.of<AuthService>(context, listen: false);
  await showDialog(
    context: context,
    builder: (ctx) => AddTransportContactDialog(
      authService: authService,
      transportService: transportService,
      extraGateways: extraGateways,
    ),
  );
}

class AddTransportContactDialog extends StatefulWidget {
  final AuthService authService;
  final TransportService? transportService;
  final List<Map<String, String>> extraGateways;

  const AddTransportContactDialog({
    super.key,
    required this.authService,
    this.transportService,
    this.extraGateways = const [],
  });

  @override
  State<AddTransportContactDialog> createState() => _AddTransportContactDialogState();
}

class _AddTransportContactDialogState extends State<AddTransportContactDialog> {
  TransportService? _ownedTransportService;
  TransportService get _transportService {
    if (widget.transportService != null) return widget.transportService!;
    if (_ownedTransportService != null) return _ownedTransportService!;
    final conn = widget.authService.activeXmppConnection;
    if (conn == null) throw Exception('No active XMPP connection');
    final ts = TransportService(conn);
    ts.setDatabase(DatabaseService());
    ts.setAccountId(widget.authService.activeAccountId);
    ts.startListening();
    _ownedTransportService = ts;
    return ts;
  }

  List<Map<String, dynamic>> _registeredTransports = [];
  Map<String, String>? _selectedTransport;
  final _addressController = TextEditingController();
  bool _isTranslating = false;
  String? _translatedJid;
  String? _errorMessage;
  List<Map<String, String>> _searchResults = [];

  @override
  void initState() {
    super.initState();
    _loadRegisteredTransports();
  }

  @override
  void dispose() {
    _ownedTransportService?.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _loadRegisteredTransports() async {
    final registered = await _transportService.getRegisteredTransports();
    final accountId = widget.authService.activeAccountId;
    setState(() {
      _registeredTransports = registered.where((r) {
        final rAccountId = r['account_id'] as String?;
        return rAccountId == null || rAccountId == accountId;
      }).toList();
    });
  }

  List<Map<String, String>> get _availableGateways {
    final registered = _registeredTransports.map((r) => {
      'jid': (r['gateway_jid'] ?? '') as String,
      'name': (r['gateway_name'] ?? r['gateway_type'] ?? 'Gateway') as String,
      'type': (r['gateway_type'] ?? 'gateway') as String,
    }).toList();
    return [...registered, ...widget.extraGateways];
  }

  Future<void> _translate() async {
    if (_selectedTransport == null) {
      setState(() => _errorMessage = 'Please select a transport first');
      return;
    }
    final address = _addressController.text.trim();
    if (address.isEmpty) {
      setState(() => _errorMessage = 'Please enter an address');
      return;
    }

    setState(() {
      _isTranslating = true;
      _errorMessage = null;
      _translatedJid = null;
      _searchResults = [];
    });

    try {
      final jid = await _transportService.translateGatewayAddress(
        _selectedTransport!['jid']!,
        address,
      );
      if (jid == null || jid.isEmpty) {
        setState(() => _errorMessage = 'Could not translate that address. Try a different format.');
      } else {
        setState(() => _translatedJid = jid);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Translation failed: $e');
    } finally {
      setState(() => _isTranslating = false);
    }
  }

  Future<void> _search() async {
    if (_selectedTransport == null) {
      setState(() => _errorMessage = 'Please select a transport first');
      return;
    }
    final address = _addressController.text.trim();
    if (address.isEmpty) {
      setState(() => _errorMessage = 'Please enter an address');
      return;
    }

    setState(() {
      _isTranslating = true;
      _errorMessage = null;
      _translatedJid = null;
      _searchResults = [];
    });

    try {
      final results = await _transportService.searchGatewayContacts(
        _selectedTransport!['jid']!,
        address,
      );
      if (results.isEmpty) {
        setState(() => _errorMessage = 'No contacts found. Try direct translation instead.');
      } else {
        setState(() => _searchResults = results);
      }
    } catch (e) {
      setState(() => _errorMessage = 'Search failed: $e');
    } finally {
      setState(() => _isTranslating = false);
    }
  }

  Future<void> _addContact(String jid, {String? name}) async {
    widget.authService.addContact(
      jid,
      nickname: name,
      group: _selectedTransport?['type']?.toUpperCase(),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Friend request sent to ${name ?? jid}')),
      );
      Navigator.pop(context);
    }
  }

  String _hintForType(String type) {
    switch (type.toLowerCase()) {
      case 'telegram':
        return 'Telegram username, e.g. @username';
      case 'discord':
        return 'Discord user ID, e.g. 1234567890';
      case 'whatsapp':
        return 'Phone number, e.g. +1234567890';
      case 'irc':
        return 'IRC nickname or channel, e.g. #general';
      case 'matrix':
        return 'Matrix ID, e.g. @alice:matrix.org';
      case 'sms':
        return 'Phone number, e.g. +1234567890';
      default:
        return 'Enter address on this service';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gateways = _availableGateways;

    return AlertDialog(
      title: const Text('Add Contact via Transport'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (gateways.isEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_rounded, color: theme.colorScheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'No registered transports. Go to Connections and register a bridge or gateway first.',
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                )
              else
                DropdownButtonFormField<Map<String, String>>(
                  decoration: const InputDecoration(
                    labelText: 'Transport',
                    prefixIcon: Icon(Icons.swap_horiz_rounded),
                  ),
                  value: _selectedTransport,
                  items: gateways.map((g) {
                    return DropdownMenuItem<Map<String, String>>(
                      value: g,
                      child: Text('${g['name']} (${g['jid']})'),
                    );
                  }).toList(),
                  onChanged: (val) {
                    setState(() {
                      _selectedTransport = val;
                      _translatedJid = null;
                      _searchResults = [];
                      _errorMessage = null;
                    });
                  },
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _addressController,
                decoration: InputDecoration(
                  labelText: 'Address',
                  hintText: _selectedTransport != null ? _hintForType(_selectedTransport!['type']!) : 'Select a transport first',
                  prefixIcon: const Icon(Icons.person_search_rounded),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _selectedTransport == null || _isTranslating ? null : _translate,
                      icon: _isTranslating
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.translate_rounded),
                      label: const Text('Translate'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _selectedTransport == null || _isTranslating ? null : _search,
                      icon: _isTranslating
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.search_rounded),
                      label: const Text('Search'),
                    ),
                  ),
                ],
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(_errorMessage!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              if (_translatedJid != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Translated address', style: TextStyle(fontSize: 12, color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7))),
                            Text(_translatedJid!, style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.person_add_rounded),
                        tooltip: 'Add contact',
                        onPressed: () => _addContact(_translatedJid!),
                      ),
                    ],
                  ),
                ),
              ],
              if (_searchResults.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Search results', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                ..._searchResults.map((r) {
                  final jid = r['jid'] ?? '';
                  final name = r['nick'] ?? r['first'] ?? r['username'] ?? jid;
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.person_outline_rounded),
                    title: Text(name),
                    subtitle: jid != name ? Text(jid) : null,
                    trailing: IconButton(
                      icon: const Icon(Icons.person_add_rounded),
                      onPressed: () => _addContact(jid, name: name),
                    ),
                  );
                }).toList(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CLOSE'),
        ),
      ],
    );
  }
}
