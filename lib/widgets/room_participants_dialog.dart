import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../models/chat_models.dart';

class RoomParticipantsDialog extends StatelessWidget {
  final String roomJid;
  final String roomName;

  const RoomParticipantsDialog({
    super.key,
    required this.roomJid,
    required this.roomName,
  });

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return StreamBuilder<Map<String, List<String>>>(
      stream: authService.roomParticipantsStream,
      builder: (context, snapshot) {
        final participants = authService.joinedRooms.firstWhere((r) => r.id == roomJid, orElse: () => Room(id: roomJid, name: roomName, participants: [], protocol: 'XMPP')).participants;
        // If we have live data from the stream, use it, otherwise fall back to the Room model
        final liveParticipants = snapshot.data?[roomJid.toLowerCase()] ?? participants;

        return AlertDialog(
          title: Text('Participants ($roomName)'),
          content: SizedBox(
            width: double.maxFinite,
            child: liveParticipants.isEmpty
                ? const Center(child: Text('No participants found.'))
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: liveParticipants.length,
                    itemBuilder: (context, index) {
                      final nick = liveParticipants[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF00BCD4).withValues(alpha: 0.1),
                          child: Text(nick[0].toUpperCase(), style: const TextStyle(color: Color(0xFF00BCD4), fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                        title: Text(nick, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        trailing: const Icon(Icons.circle, color: Colors.green, size: 8),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CLOSE'),
            ),
          ],
        );
      },
    );
  }
}
