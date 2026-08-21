import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import '../models/chat_models.dart';
import '../services/database_service.dart';

class ChatSettingsScreen extends StatefulWidget {
  final Conversation conversation;

  const ChatSettingsScreen({super.key, required this.conversation});

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  late bool _muteNotifications;
  late bool _messagePreview;
  String _notificationSound = 'Default';
  int? _currentWallpaperColor;

  @override
  void initState() {
    super.initState();
    _muteNotifications = false;
    _messagePreview = true;
    _currentWallpaperColor = widget.conversation.wallpaperColor;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat settings'),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Notifications',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Mute notifications'),
            subtitle: const Text('Temporarily silence this chat'),
            value: _muteNotifications,
            onChanged: (val) {
              setState(() => _muteNotifications = val);
              _saveNotificationSettings();
            },
          ),
          SwitchListTile(
            title: const Text('Message preview'),
            subtitle: const Text('Show message content in notifications'),
            value: _messagePreview,
            onChanged: (val) {
              setState(() => _messagePreview = val);
              _saveNotificationSettings();
            },
          ),
          ListTile(
            title: const Text('Notification sound'),
            subtitle: Text(_notificationSound),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              _showSoundPicker(context);
            },
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Privacy',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Read receipts'),
            subtitle: const Text('Send read receipts for messages'),
            value: true,
            onChanged: (val) {},
          ),
          SwitchListTile(
            title: const Text('Typing indicators'),
            subtitle: const Text('Let others know when you are typing'),
            value: true,
            onChanged: (val) {},
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: const Text('Chat wallpaper'),
            subtitle: _currentWallpaperColor != null
                ? const Text('Custom color set')
                : const Text('Default'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_currentWallpaperColor != null)
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Color(_currentWallpaperColor!),
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.colorScheme.outline),
                    ),
                  ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
            onTap: () => _showWallpaperPicker(context),
          ),
          ListTile(
            leading: const Icon(Icons.search_rounded),
            title: const Text('Search in conversation'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {},
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.delete_forever_rounded, color: theme.colorScheme.error),
            title: Text('Delete chat', style: TextStyle(color: theme.colorScheme.error)),
            onTap: () {
              _showDeleteConfirmation(context);
            },
          ),
        ],
      ),
    );
  }

  void _saveNotificationSettings() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Notification settings saved')),
    );
  }

  void _showSoundPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Notification sound',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ListTile(
              title: const Text('Default'),
              trailing: _notificationSound == 'Default'
                  ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                  : null,
              onTap: () {
                setState(() => _notificationSound = 'Default');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('Silent'),
              trailing: _notificationSound == 'Silent'
                  ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                  : null,
              onTap: () {
                setState(() => _notificationSound = 'Silent');
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showWallpaperPicker(BuildContext context) {
    Color pickerColor = _currentWallpaperColor != null
        ? Color(_currentWallpaperColor!)
        : Theme.of(context).colorScheme.surface;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('Chat Wallpaper',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const Spacer(),
                    if (_currentWallpaperColor != null)
                      TextButton(
                        onPressed: () async {
                          await _setWallpaperColor(null);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: const Text('Reset'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 300,
                  child: ColorPicker(
                    pickerColor: pickerColor,
                    onColorChanged: (color) => pickerColor = color,
                    enableAlpha: false,
                    displayThumbColor: true,
                    pickerAreaHeightPercent: 0.7,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      await _setWallpaperColor(pickerColor.toARGB32());
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _setWallpaperColor(int? color) async {
    setState(() => _currentWallpaperColor = color);
    widget.conversation.wallpaperColor = color;
    await DatabaseService().updateConversationWallpaper(
      widget.conversation.id,
      widget.conversation.wallpaperPath,
      color,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(color != null ? 'Wallpaper color updated' : 'Wallpaper reset to default'),
        ),
      );
    }
  }

  void _showDeleteConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete chat?'),
        content: const Text(
            'This will delete messages on this device only. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('DELETE', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
