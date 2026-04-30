import 'dart:io';

void main() {
  final file = File('lib/services/auth_service.dart');
  final lines = file.readAsLinesSync();

  final outLines = <String>[];
  int i = 0;
  bool inTargetMethod = false;
  int braceCount = 0;

  final methodsToStrip = [
    'Future<void> connectIrc(',
    'void _monitorDiscordHealth(',
    'Future<String> connectDiscord(',
    'Future<String> _connectDiscord(',
    'Future<void> _discoverDiscordGuilds(',
    'Future<void> sendDiscordReaction(',
    'Future<void> deleteDiscordMessage(',
    'Future<void> editDiscordMessage(',
    'Future<void> _reconnectDiscord(',
    'ContactStatus _mapDiscordStatus(',
    'discord.CurrentUserStatus _mapStatusToDiscord(',
    'void _handleIrcMessage(',
    'void _handleIrcEvent(',
  ];

  while (i < lines.length) {
    final line = lines[i];

    if (!inTargetMethod) {
      bool isTarget = false;
      for (final m in methodsToStrip) {
        if (line.trim().startsWith(m)) {
          isTarget = true;
          break;
        }
      }

      if (isTarget) {
        inTargetMethod = true;
        braceCount = '{'.allMatches(line).length - '}'.allMatches(line).length;
        if (braceCount == 0 && !line.contains('{')) {
          int j = i + 1;
          while (j < lines.length && !lines[j].contains('{')) {
            j++;
          }
          if (j < lines.length) {
            braceCount = '{'.allMatches(lines[j]).length - '}'.allMatches(lines[j]).length;
            i = j;
          }
        }
        i++;
        continue;
      }

      outLines.add(line);
      i++;
    } else {
      braceCount += '{'.allMatches(line).length - '}'.allMatches(line).length;
      if (braceCount <= 0) {
        inTargetMethod = false;
      }
      i++;
    }
  }

  file.writeAsStringSync(outLines.join('\n') + '\n');
}
