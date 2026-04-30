import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

class RoomInfoScreen extends StatelessWidget {
  final Map<String, dynamic> room;
  final String accountId;

  const RoomInfoScreen({
    super.key,
    required this.room,
    required this.accountId,
  });

  Future<void> _joinRoom(BuildContext context) async {
    final authService = Provider.of<AuthService>(context, listen: false);
    final nickname = authService.currentProfile?.nickName ?? 
                     authService.currentProfile?.displayName ?? 'User';
    
    // Show a loading indicator if necessary (optional, but good UX)
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Joining ${room['name']}...'), duration: const Duration(seconds: 1)),
    );

    try {
      await authService.joinRoom(accountId, room['jid']!, nickname);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Joined ${room['name']}'), backgroundColor: Colors.green),
        );
        Navigator.pop(context); // Pop info screen
        Navigator.pop(context); // Pop discovery screen to return to chat
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to join: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    final name = (room['name'] ?? 'Untitled Room').replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    final jid = room['jid'] ?? 'Unknown JID';
    final topic = (room['topic'] != null && room['topic']!.isNotEmpty ? room['topic']! : 'No topic set')
        .replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
    const protocol = 'XMPP';
    final userCount = (room['users'] ?? '0').trim();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Room Details', style: TextStyle(fontWeight: FontWeight.w900)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              color: theme.colorScheme.surface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Background Gradient matching Cyberpunk aesthetic
          Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 1.5,
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.15),
                  theme.scaffoldBackgroundColor,
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hero Icon
                  Center(
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        border: Border.all(
                          color: theme.colorScheme.primary.withValues(alpha: 0.3),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(alpha: 0.2),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.groups_rounded,
                        size: 50,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  
                  // Room Name
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                  ),
                  const SizedBox(height: 8),
                  
                  // Protocol Badge
                  Center(
                    child: Container(
                      child: Text(
                        protocol,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  
                  // Details Card
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildDetailRow(context, Icons.link_rounded, 'Address', jid),
                                const SizedBox(height: 24),
                                _buildDetailRow(context, Icons.people_rounded, 'Users', userCount),
                                const SizedBox(height: 24),
                                _buildDetailRow(context, Icons.format_quote_rounded, 'Topic', topic, isTopic: true),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // Join Button
                  ElevatedButton(
                    onPressed: () => _joinRoom(context),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 8,
                      shadowColor: theme.colorScheme.primary.withValues(alpha: 0.5),
                    ),
                    child: const Text(
                      'CONNECT TO ROOM',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(BuildContext context, IconData icon, String label, String value, {bool isTopic = false}) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: isTopic ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary.withValues(alpha: 0.7)),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                  fontStyle: isTopic && value == 'No topic set' ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
