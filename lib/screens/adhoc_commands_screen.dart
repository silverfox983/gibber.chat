import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service.dart';
import '../services/xmpp_server_info_service.dart';
import '../models/chat_models.dart';

class AdHocCommandsScreen extends StatefulWidget {
  final String? initialTargetJid;
  const AdHocCommandsScreen({super.key, this.initialTargetJid});

  @override
  State<AdHocCommandsScreen> createState() => _AdHocCommandsScreenState();
}

class _AdHocCommandsScreenState extends State<AdHocCommandsScreen> {
  List<AdHocCommand> _commands = [];
  bool _isLoading = true;
  String? _error;
  String _selectedAccountId = '';
  String _targetJid = '';
  AdHocCommandResult? _activeResult;
  Map<String, String> _formValues = {};
  String? _sessionId;
  String? _commandNode;
  String? _commandJid;

  @override
  void initState() {
    super.initState();
    _targetJid = widget.initialTargetJid ?? '';
    _loadAccounts();
  }

  void _loadAccounts() {
    final auth = context.read<AuthService>();
    final accounts = auth.savedAccounts.where((a) => a.protocol == 'XMPP').toList();
    if (accounts.isNotEmpty) {
      _selectedAccountId = accounts.first.fullJid;
      if (_targetJid.isEmpty) {
        _targetJid = accounts.first.fullJid.split('@').lastOrNull ?? '';
      }
    }
    _fetchCommands();
  }

  Future<void> _fetchCommands() async {
    if (_selectedAccountId.isEmpty) return;
    setState(() { _isLoading = true; _error = null; _activeResult = null; });

    try {
      final auth = context.read<AuthService>();
      final serverInfo = auth.getServerInfoService(_selectedAccountId);
      if (serverInfo == null) {
        setState(() { _error = 'Server info service not available'; _isLoading = false; });
        return;
      }
      final target = _targetJid.isEmpty ? null : _targetJid;
      final commands = await serverInfo.fetchAdHocCommands(_selectedAccountId, targetJid: target);
      setState(() { _commands = commands; _isLoading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<void> _executeCommand(AdHocCommand cmd) async {
    setState(() { _isLoading = true; _error = null; });
    _commandNode = cmd.node;
    _commandJid = cmd.jid;

    try {
      final auth = context.read<AuthService>();
      final serverInfo = auth.getServerInfoService(_selectedAccountId);
      if (serverInfo == null) { setState(() { _isLoading = false; }); return; }

      final result = await serverInfo.executeAdHocCommand(
        accountId: _selectedAccountId,
        commandJid: cmd.jid,
        commandNode: cmd.node,
      );
      _sessionId = result.sessionId;
      _formValues = {};
      setState(() { _activeResult = result; _isLoading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<void> _submitForm() async {
    if (_commandNode == null || _commandJid == null) return;
    setState(() { _isLoading = true; _error = null; });

    try {
      final auth = context.read<AuthService>();
      final serverInfo = auth.getServerInfoService(_selectedAccountId);
      if (serverInfo == null) { setState(() { _isLoading = false; }); return; }

      final result = await serverInfo.executeAdHocCommand(
        accountId: _selectedAccountId,
        commandJid: _commandJid!,
        commandNode: _commandNode!,
        sessionId: _sessionId,
        formValues: _formValues,
        action: 'execute',
      );
      _sessionId = result.sessionId ?? _sessionId;
      setState(() { _activeResult = result; _isLoading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  Future<void> _cancelCommand() async {
    if (_commandNode == null || _commandJid == null) return;
    setState(() { _isLoading = true; });

    try {
      final auth = context.read<AuthService>();
      final serverInfo = auth.getServerInfoService(_selectedAccountId);
      if (serverInfo != null) {
        await serverInfo.executeAdHocCommand(
          accountId: _selectedAccountId,
          commandJid: _commandJid!,
          commandNode: _commandNode!,
          sessionId: _sessionId,
          action: 'cancel',
        );
      }
    } catch (_) {}
    setState(() { _activeResult = null; _sessionId = null; _isLoading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final accounts = auth.savedAccounts.where((a) => a.protocol == 'XMPP').toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Server Commands'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ACCOUNT', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _selectedAccountId.isEmpty ? null : _selectedAccountId,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  items: accounts.map((a) => DropdownMenuItem(value: a.fullJid, child: Text(a.fullJid, overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (v) { if (v != null) { setState(() { _selectedAccountId = v; }); _fetchCommands(); } },
                ),
                const SizedBox(height: 16),
                Text('TARGET ENTITY (optional)', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                TextField(
                  controller: TextEditingController(text: _targetJid),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    hintText: 'Server domain or JID (defaults to your server)',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  onChanged: (v) => _targetJid = v,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _fetchCommands,
                    icon: const Icon(Icons.search),
                    label: const Text('Discover Commands'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error), textAlign: TextAlign.center)))
                    : _activeResult != null
                        ? _buildResultView()
                        : _buildCommandList(),
          ),
        ],
      ),
    );
  }

  Widget _buildCommandList() {
    if (_commands.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.terminal, size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text('No commands discovered', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 16)),
          const SizedBox(height: 8),
          Text('Select an account and tap Discover Commands', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
        ]),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _commands.length,
      itemBuilder: (context, i) {
        final cmd = _commands[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(Icons.terminal, color: Theme.of(context).colorScheme.primary),
            title: Text(cmd.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(cmd.node, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _executeCommand(cmd),
          ),
        );
      },
    );
  }

  Widget _buildResultView() {
    final result = _activeResult!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (result.noteText != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: result.isError ? Theme.of(context).colorScheme.errorContainer : Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(result.isError ? Icons.error_outline : Icons.check_circle_outline, color: result.isError ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(child: Text(result.noteText!, style: TextStyle(color: result.isError ? Theme.of(context).colorScheme.onErrorContainer : Theme.of(context).colorScheme.onPrimaryContainer))),
            ]),
          ),
        if (result.hasForm) ...[
          for (final form in result.forms) ...[
            if (form.title != null)
              Text(form.title!, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            if (form.instructions.isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(form.instructions.join('\n'), style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
            const SizedBox(height: 8),
            for (final field in form.fields)
              if (field.varAttr != 'FORM_TYPE') _buildFormField(field),
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _submitForm, icon: const Icon(Icons.play_arrow), label: const Text('Execute'))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _cancelCommand, child: const Text('Cancel')),
          ]),
        ] else if (!result.isError && result.isExecuting)
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: _cancelCommand, icon: const Icon(Icons.close), label: const Text('Cancel'))),
          ]),
        if (!result.hasForm && !result.isExecuting) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(onPressed: () { setState(() { _activeResult = null; _sessionId = null; }); }, icon: const Icon(Icons.arrow_back), label: const Text('Back to Commands')),
        ],
      ]),
    );
  }

  Widget _buildFormField(AdHocFormField field) {
    final controller = TextEditingController(text: field.values.isNotEmpty ? field.values.first : '');
    if (!_formValues.containsKey(field.varAttr)) {
      _formValues[field.varAttr] = field.values.isNotEmpty ? field.values.first : '';
    }

    if (field.type == 'hidden') return const SizedBox.shrink();

    if (field.type == 'boolean') {
      return SwitchListTile(
        title: Text(field.label ?? field.varAttr),
        value: _formValues[field.varAttr] == '1' || _formValues[field.varAttr] == 'true',
        onChanged: (v) { setState(() { _formValues[field.varAttr] = v ? '1' : '0'; }); },
      );
    }

    if (field.type == 'list-single' && field.options.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          value: _formValues[field.varAttr] ?? field.values.firstOrNull ?? field.options.first.value,
          decoration: InputDecoration(
            labelText: field.label ?? field.varAttr,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          items: field.options.map((o) => DropdownMenuItem(value: o.value, child: Text(o.label ?? o.value))).toList(),
          onChanged: (v) { if (v != null) setState(() { _formValues[field.varAttr] = v; }); },
        ),
      );
    }

    if (field.type == 'list-multi' && field.options.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: InputDecorator(
          decoration: InputDecoration(labelText: field.label ?? field.varAttr, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
          child: Column(children: field.options.map((o) => CheckboxListTile(
            title: Text(o.label ?? o.value),
            value: _formValues['${field.varAttr}_${o.value}'] == o.value,
            onChanged: (v) { setState(() { _formValues['${field.varAttr}_${o.value}'] = v == true ? o.value : ''; }); },
            dense: true, controlAffinity: ListTileControlAffinity.leading,
          )).toList()),
        ),
      );
    }

    final isMultiLine = field.type == 'text-multi' || field.type == 'jid-multi';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        maxLines: isMultiLine ? 4 : 1,
        decoration: InputDecoration(
          labelText: field.label ?? field.varAttr,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          suffixIcon: field.isRequired ? Padding(padding: const EdgeInsets.only(right: 8), child: Icon(Icons.star, size: 12, color: Theme.of(context).colorScheme.error)) : null,
        ),
        onChanged: (v) { _formValues[field.varAttr] = v; },
      ),
    );
  }
}