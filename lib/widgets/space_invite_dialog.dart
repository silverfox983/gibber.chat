import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/spaces_service.dart';

class SpaceInviteDialog extends StatefulWidget {
  final SpacesService spacesService;
  final String domain;
  final String node;

  const SpaceInviteDialog({
    super.key,
    required this.spacesService,
    required this.domain,
    required this.node,
  });

  @override
  State<SpaceInviteDialog> createState() => _SpaceInviteDialogState();
}

class _SpaceInviteDialogState extends State<SpaceInviteDialog> {
  final _jidCtrl = TextEditingController();
  String _affiliation = 'member';
  bool _loading = false;

  @override
  void dispose() {
    _jidCtrl.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    final jid = _jidCtrl.text.trim();
    if (jid.isEmpty || !jid.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid JID (user@domain)')));
      return;
    }
    setState(() => _loading = true);
    final ok = await widget.spacesService.inviteMember(
      widget.domain, widget.node, jid, _affiliation,
    );
    if (mounted) {
      setState(() => _loading = false);
      Navigator.pop(context, ok);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? 'Invited $jid as $_affiliation' : 'Failed to invite member')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Invite Member', style: GoogleFonts.inter(
              fontWeight: FontWeight.w900, fontSize: 20)),
          const SizedBox(height: 4),
          Text('Invite someone to this space by their XMPP address.',
              style: GoogleFonts.inter(fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 20),
          TextField(
            controller: _jidCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'JID',
              hintText: 'user@domain.tld',
              prefixIcon: const Icon(Icons.person_add_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 14),
          Text('Role', style: GoogleFonts.inter(
              fontWeight: FontWeight.w700, fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            _roleChip(theme, 'member', Icons.people_rounded, 'Member'),
            _roleChip(theme, 'publisher', Icons.edit_note_rounded, 'Publisher'),
            _roleChip(theme, 'owner', Icons.shield_rounded, 'Owner'),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _loading ? null : _invite,
                icon: _loading
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 16),
                label: Text(_loading ? 'Inviting…' : 'Invite'),
                style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _roleChip(ThemeData theme, String value, IconData icon, String label) {
    final selected = _affiliation == value;
    return ChoiceChip(
      avatar: Icon(icon, size: 15,
          color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant),
      label: Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600)),
      selected: selected,
      onSelected: (_) => setState(() => _affiliation = value),
      selectedColor: theme.colorScheme.primary,
      labelStyle: TextStyle(
          color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
    );
  }
}
