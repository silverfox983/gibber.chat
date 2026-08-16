import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'dart:typed_data';
import '../services/auth_service.dart';
import '../services/avatar_cache_service.dart';
import '../providers/theme_provider.dart';
import '../models/chat_models.dart';

class ProfileScreen extends StatefulWidget {
  final bool isSidebar;
  const ProfileScreen({super.key, this.isSidebar = false});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _nameController;
  late TextEditingController _nickController;
  bool _isSaving = false;
  Uint8List? _avatarBytes;
  
  late TextEditingController _bioController;
  String? _selectedAccountId;
  
  // Presence Local State
  ContactStatus _localStatus = ContactStatus.online;
  late TextEditingController _statusMsgController;
  bool _syncStatus = true;

  @override
  void initState() {
    super.initState();
    final authService = Provider.of<AuthService>(context, listen: false);
    final profile = authService.currentProfile;
    final xmppAccounts = authService.savedAccounts
        .where((a) => a.protocol == 'XMPP')
        .toList();
    
    _nameController = TextEditingController(text: profile?.displayName ?? '');
    _nickController = TextEditingController(text: profile?.nickName ?? '');
    _bioController = TextEditingController(text: profile?.bio ?? '');
    _localStatus = authService.myStatus;
    _statusMsgController = TextEditingController(text: authService.myStatusMessage ?? '');
    
    if (xmppAccounts.isNotEmpty) {
      _selectedAccountId = xmppAccounts.first.fullJid;
      _loadInitialAvatar(_selectedAccountId!);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nickController.dispose();
    _bioController.dispose();
    _statusMsgController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (_selectedAccountId == null) return;
    
    setState(() => _isSaving = true);
    
    try {
      final authService = Provider.of<AuthService>(context, listen: false);
      
      // Update Presence
      if (_syncStatus) {
        await authService.updateMyStatus(_localStatus, message: _statusMsgController.text.trim().isEmpty ? null : _statusMsgController.text.trim());
      } else {
        await authService.setPresence(_localStatus, _statusMsgController.text.trim().isEmpty ? null : _statusMsgController.text.trim());
      }
      
      // Update VCard
      await authService.updateMyVCard(
        accountId: _selectedAccountId!,
        fullName: _nameController.text,
        nickName: _nickController.text,
        description: _bioController.text,
      );
      
      if (mounted) {
        if (!widget.isSidebar) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('Profile & Status Updated!'), backgroundColor: Colors.green),
           );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating profile: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _loadInitialAvatar(String jid) async {
    final bytes = await AvatarCacheService().getAvatar(jid);
    if (mounted) {
      setState(() => _avatarBytes = bytes);
    }
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null && !kIsWeb) {
      final file = File(result.files.single.path!);
      final bytes = await file.readAsBytes();
      setState(() {
         _avatarBytes = bytes;
      });
      
      // Auto-save avatar if we have a selected account
      if (_selectedAccountId != null && mounted) {
         final authService = Provider.of<AuthService>(context, listen: false);
         await authService.setMyAvatar(_selectedAccountId!, file);
      }
    } else if (result != null && kIsWeb && result.files.single.bytes != null) {
      setState(() {
         _avatarBytes = result.files.single.bytes!;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final profile = authService.currentProfile;
    final xmppAccounts = authService.savedAccounts
        .where((a) => a.protocol == 'XMPP')
        .toList();
    final hasXmppAccounts = xmppAccounts.isNotEmpty;
    final selectedXmppAccountId =
        xmppAccounts.any((a) => a.fullJid == _selectedAccountId)
        ? _selectedAccountId
        : (hasXmppAccounts ? xmppAccounts.first.fullJid : null);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text('Edit Profile', style: TextStyle(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary)),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
        elevation: 0,
        leading: widget.isSidebar ? null : IconButton(
          icon: Icon(Icons.arrow_back, color: Theme.of(context).colorScheme.onPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
            )
          else
            IconButton(
              icon: Icon(Icons.check_rounded, color: Theme.of(context).colorScheme.onPrimary),
              onPressed: _saveProfile,
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Opaque Header (GPU Hardened)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.primary,
              padding: const EdgeInsets.only(bottom: 40),
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  GestureDetector(
                    onTap: _pickAvatar,
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        FutureBuilder<Uint8List?>(
                          future: _avatarBytes != null 
                              ? Future.value(_avatarBytes) 
                              : AvatarCacheService().getAvatar(selectedXmppAccountId?.split('/').first ?? ''),
                          builder: (context, snapshot) {
                            final displayBytes = snapshot.data;
                            return Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.24),
                                shape: BoxShape.circle,
                                border: Border.all(color: Theme.of(context).colorScheme.onPrimary, width: 4),
                                image: displayBytes != null 
                                  ? DecorationImage(image: MemoryImage(displayBytes), fit: BoxFit.cover)
                                  : null,
                              ),
                              child: displayBytes == null 
                                ? Icon(Icons.person_rounded, size: 80, color: Theme.of(context).colorScheme.onPrimary)
                                : null,
                            );
                          }
                        ),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondary, shape: BoxShape.circle),
                          child: Icon(Icons.camera_alt_rounded, color: Theme.of(context).colorScheme.onSecondary, size: 18),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    profile?.displayName ?? 'New User',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.onPrimary),
                  ),
                  Text(
                    profile?.nickName ?? 'No nickname set',
                    style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('IDENTITY SETTINGS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                  const SizedBox(height: 16),
                  _buildTextField('Full Name', _nameController, Icons.badge_rounded),
                  const SizedBox(height: 16),
                  _buildTextField('Nickname', _nickController, Icons.alternate_email_rounded),
                  const SizedBox(height: 16),
                  _buildTextField('Biography', _bioController, Icons.info_outline_rounded, maxLines: 3),
                  
                  const SizedBox(height: 32),
                  Text('AVAILABILITY', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Status Message', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        TextField(
                          controller: _statusMsgController,
                          decoration: const InputDecoration(
                            hintText: 'What\'s on your mind?',
                            border: InputBorder.none,
                          ),
                        ),
                        const Divider(),
                        const SizedBox(height: 8),
                        Text('Presence State', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 12),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SegmentedButton<ContactStatus>(
                            segments: const [
                              ButtonSegment(value: ContactStatus.online, label: Text('Online'), icon: Icon(Icons.circle, color: Colors.green, size: 12)),
                              ButtonSegment(value: ContactStatus.away, label: Text('Away'), icon: Icon(Icons.circle, color: Colors.amber, size: 12)),
                              ButtonSegment(value: ContactStatus.dnd, label: Text('DND'), icon: Icon(Icons.circle, color: Colors.red, size: 12)),
                            ],
                            selected: {_localStatus},
                            onSelectionChanged: (set) => setState(() => _localStatus = set.first),
                            style: SegmentedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.surface,
                              selectedBackgroundColor: Theme.of(context).colorScheme.primary,
                              selectedForegroundColor: Theme.of(context).colorScheme.onPrimary,
                              side: BorderSide(color: Theme.of(context).colorScheme.outline),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          value: _syncStatus,
                          onChanged: (val) => setState(() => _syncStatus = val),
                          title: const Text('Sync Across Accounts', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          subtitle: const Text('Apply this status across all your connected XMPP nodes', style: TextStyle(fontSize: 10)),
                          activeThumbColor: Theme.of(context).colorScheme.primary,
                          contentPadding: EdgeInsets.all(0),
                          dense: true,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),
                  Text(
                    'PRIMARY XMPP ACCOUNT',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: selectedXmppAccountId,
                        items: xmppAccounts.map((acc) {
                          return DropdownMenuItem(
                            value: acc.fullJid,
                            child: Text(
                              acc.fullJid,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        }).toList(),
                        onChanged: hasXmppAccounts
                            ? (val) => setState(() => _selectedAccountId = val)
                            : null,
                      ),
                    ),
                  ),
                  if (!hasXmppAccounts)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'VCard profile sync currently requires an XMPP account.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      onPressed:
                          (_isSaving || !hasXmppAccounts) ? null : _saveProfile,
                      child: const Text('SAVE GLOBAL IDENTITY', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  Text('APPEARANCE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: Consumer<ThemeProvider>(
                      builder: (context, themeProv, _) {
                        return Column(
                          children: [
                            ListTile(
                              leading: Icon(Icons.brightness_medium_rounded, color: Theme.of(context).colorScheme.primary),
                              title: const Text('Theme Mode', style: TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text(themeProv.themeMode.name.toUpperCase()),
                              trailing: Switch(
                                value: themeProv.isDarkMode,
                                onChanged: (_) => themeProv.toggleTheme(),
                                activeThumbColor: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  Text('CONFIGURATIONS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 1.2)),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          leading: Icon(Icons.settings_applications_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          title: const Text('Manage Connected Accounts', style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: const Text('Edit XMPP hosts, ports, and credentials'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            context.goNamed('preferences');
                          },
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.security_rounded, color: Theme.of(context).colorScheme.primary),
                          title: const Text('Security & Privacy', style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: const Text('Encryption keys, blocking, and history'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            context.goNamed('security');
                          },
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.video_library_rounded, color: Colors.green),
                          title: const Text('Call Recordings', style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: const Text('View and play your saved calls'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            context.goNamed('recordings');
                          },
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(Icons.workspace_premium_rounded, color: Colors.amber),
                          title: const Text('Tier & Mining', style: TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: const Text('Manage your plan, mine credits, redeem codes'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            context.goNamed('tier');
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, IconData icon, {int maxLines = 1}) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: Theme.of(context).colorScheme.secondary),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(16),
          labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
