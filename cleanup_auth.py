import os
import re

def strip_methods(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    out_lines = []
    i = 0
    in_target_method = False
    brace_count = 0

    methods_to_strip = [
        "Future<void> connectIrc(",
        "void _monitorDiscordHealth(",
        "Future<String> connectDiscord(",
        "Future<String> _connectDiscord(",
        "Future<void> _discoverDiscordGuilds(",
        "Future<void> sendDiscordReaction(",
        "Future<void> deleteDiscordMessage(",
        "Future<void> editDiscordMessage(",
        "Future<void> _reconnectDiscord(",
        "ContactStatus _mapDiscordStatus(",
        "discord.CurrentUserStatus _mapStatusToDiscord(",
        "void _handleIrcMessage(",
        "void _handleIrcEvent(",
    ]

    while i < len(lines):
        line = lines[i]
        
        if not in_target_method:
            is_target = False
            for m in methods_to_strip:
                if line.strip().startswith(m) or (i+1 < len(lines) and (line.strip() + lines[i+1].strip()).startswith(m)):
                    is_target = True
                    break
            
            if is_target:
                in_target_method = True
                brace_count = line.count('{') - line.count('}')
                if brace_count == 0 and '{' not in line:
                    # Look ahead for brace
                    j = i + 1
                    while j < len(lines) and '{' not in lines[j]:
                        j += 1
                    if j < len(lines):
                        brace_count = lines[j].count('{') - lines[j].count('}')
                        i = j
                i += 1
                continue
            
            out_lines.append(line)
            i += 1
        else:
            brace_count += line.count('{') - line.count('}')
            if brace_count <= 0:
                in_target_method = False
            i += 1

    with open(filepath, 'w', encoding='utf-8') as f:
        f.writelines(out_lines)

strip_methods('lib/services/auth_service.dart')
