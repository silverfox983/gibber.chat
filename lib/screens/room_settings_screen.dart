import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/chat_models.dart';
import '../models/xdata_form_model.dart';
import '../services/auth_service.dart';
import '../widgets/xdata/xdata_form_widget.dart';

class RoomSettingsScreen extends StatefulWidget {
  final Conversation room;

  const RoomSettingsScreen({super.key, required this.room});

  @override
  State<RoomSettingsScreen> createState() => _RoomSettingsScreenState();
}

class _RoomSettingsScreenState extends State<RoomSettingsScreen> {
  bool _isLoading = false;
  bool _isFetching = true;
  String? _fetchError;
  XdataForm? _configForm;

  @override
  void initState() {
    super.initState();
    _fetchCurrentConfig();
  }

  Future<void> _fetchCurrentConfig() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = widget.room.accountId ?? authService.activeAccountId;
    if (accountId == null) {
      if (mounted) setState(() { _isFetching = false; _fetchError = 'No active account'; });
      return;
    }

    final roomService = authService.roomService;
    if (roomService == null) {
      if (mounted) setState(() { _isFetching = false; _fetchError = 'Room service not available'; });
      return;
    }

    final response = await roomService.fetchRoomConfigForm(widget.room.id, accountId: accountId);
    if (!mounted) return;

    if (response == null) {
      setState(() { _isFetching = false; _fetchError = 'Failed to fetch room configuration'; });
      return;
    }

    final query = response.getChild('query');
    final x = query?.getChild('x');
    final form = XdataForm.parse(x);
    setState(() {
      _isFetching = false;
      _configForm = form;
      if (form == null) _fetchError = 'Could not parse room configuration form';
    });
  }

  Future<void> _submitForm(XdataForm form) async {
    setState(() => _isLoading = true);

    final authService = Provider.of<AuthService>(context, listen: false);
    final accountId = widget.room.accountId ?? authService.activeAccountId;

    if (accountId == null) {
      setState(() => _isLoading = false);
      return;
    }

    final roomService = authService.roomService;
    if (roomService == null) {
      setState(() => _isLoading = false);
      return;
    }

    final formElement = form.toSubmitElement();
    final error = await roomService.submitRoomConfigForm(widget.room.id, formElement, accountId: accountId);

    if (!mounted) return;

    setState(() => _isLoading = false);

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $error'), backgroundColor: Colors.red),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Room settings updated.')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Room Settings'),
        actions: [
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(right: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                ),
              ),
            )
          else if (_configForm != null)
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: () => _submitForm(_configForm!),
            ),
        ],
      ),
      body: _isFetching
        ? const Center(child: CircularProgressIndicator())
        : _fetchError != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(_fetchError!, style: TextStyle(color: theme.colorScheme.error)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => setState(() { _isFetching = true; _fetchError = null; _fetchCurrentConfig(); }),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : _configForm != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.redAccent, size: 18),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Configuration changes only apply if you are a Room Owner.',
                              style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: XdataFormWidget(
                        form: _configForm!,
                        onSubmit: _submitForm,
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.people_alt_rounded),
                      label: const Text('MANAGE BANS & MEMBERS'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: BorderSide(color: theme.colorScheme.primary),
                      ),
                      onPressed: () {
                        context.goNamed('roomAffiliation', extra: {'room': widget.room});
                      },
                    ),
                  ],
                ),
              )
            : const Center(child: Text('No configuration form available')),
    );
  }
}
