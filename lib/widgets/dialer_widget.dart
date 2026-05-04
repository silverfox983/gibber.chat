import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/call_history_service.dart';
import '../providers/call_provider.dart';
import '../models/call_log.dart';
import 'dart:ui';
import 'package:flutter/services.dart';

class DialerWidget extends StatefulWidget {
  final AuthService authService;
  
  const DialerWidget({super.key, required this.authService});

  @override
  State<DialerWidget> createState() => _DialerWidgetState();
}

class _DialerWidgetState extends State<DialerWidget> {
  String _dialedNumber = '';

  String _formatDialedNumber(String number, {bool isSip = false}) {
    if (number.contains('@')) return number;
    String clean = number.replaceAll(RegExp(r'[^\d+]'), '');
    final isPhone = clean.startsWith('+') || RegExp(r'^\d+$').hasMatch(clean);
    if (isPhone) {
      if (isSip) return clean;
      if (clean.startsWith('+1+1')) {
        clean = clean.replaceFirst('+1+1', '+1');
      }
      return '$clean@cheogram.com';
    }
    return clean;
  }

  void _onDial(String value) {
    setState(() {
      if (value == '+' && _dialedNumber.isEmpty) {
        _dialedNumber = '+';
      } else if (value != '+') {
        _dialedNumber += value;
      }
    });
  }

  void _onBackspace() {
    if (_dialedNumber.isNotEmpty) {
      setState(() {
        _dialedNumber = _dialedNumber.substring(0, _dialedNumber.length - 1);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = Provider.of<CallHistoryService>(context);
    final callProvider = Provider.of<CallProvider>(context, listen: false);
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
      ),
      child: Column(
        children: [
          // Header / Search area
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: [
                Text(
                  'Recents',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                const Spacer(),
                if (history.logs.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => history.clearHistory(),
                    icon: const Icon(Icons.clear_all_rounded, size: 18),
                    label: const Text('Clear'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),

          // 1. Call History List
          Expanded(
            child: history.logs.isEmpty
                ? _buildEmptyHistory(theme)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: history.logs.length,
                    itemBuilder: (context, index) {
                      final log = history.logs[index];
                      return _buildHistoryItem(log, theme);
                    },
                  ),
          ),

          // 2. Dialer Panel (Glassmorphic)
          ClipRRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.8),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 20,
                      offset: const Offset(0, -5),
                    ),
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 64,
                      alignment: Alignment.center,
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        style: theme.textTheme.headlineMedium!.copyWith(
                          fontWeight: FontWeight.w900,
                          fontSize: _dialedNumber.length > 12 ? 24 : 32,
                          color: _dialedNumber.isEmpty
                              ? theme.colorScheme.onSurface.withValues(alpha: 0.1)
                              : theme.colorScheme.primary,
                          letterSpacing: 4,
                          shadows: _dialedNumber.isEmpty ? [] : [
                            Shadow(
                              color: theme.colorScheme.primary.withValues(alpha: 0.3),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: Text(
                          _dialedNumber.isEmpty ? 'Dial' : _dialedNumber,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Protocol Indicator
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: callProvider.isSipRegistered
                                ? Colors.green.withValues(alpha: 0.15)
                                : theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: callProvider.isSipRegistered
                                  ? Colors.green.withValues(alpha: 0.3)
                                  : theme.colorScheme.outline.withValues(alpha: 0.1),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                callProvider.isSipRegistered
                                    ? Icons.check_circle_rounded
                                    : Icons.info_outline_rounded,
                                size: 14,
                                color: callProvider.isSipRegistered
                                    ? Colors.green
                                    : theme.colorScheme.outline,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                callProvider.isSipRegistered
                                    ? 'SIP REGISTERED'
                                    : 'XMPP P-PSTN',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                  color: callProvider.isSipRegistered
                                      ? Colors.green
                                      : theme.colorScheme.outline,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Numeric Grid
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.5,
                      children: [
                        _dialButton('1', ''),
                        _dialButton('2', 'ABC'),
                        _dialButton('3', 'DEF'),
                        _dialButton('4', 'GHI'),
                        _dialButton('5', 'JKL'),
                        _dialButton('6', 'MNO'),
                        _dialButton('7', 'PQRS'),
                        _dialButton('8', 'TUV'),
                        _dialButton('9', 'WXYZ'),
                        _dialButton('*', ''),
                        _dialButton('0', '+', onLongPress: () => _onDial('+')),
                        _dialButton('#', ''),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Action Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _circleButton(
                          icon: Icons.video_call_rounded,
                          color: Colors.blueAccent,
                          onPressed: () {
                            if (_dialedNumber.isNotEmpty) {
                              final isSip = callProvider.isSipRegistered;
                              callProvider.startCall(
                                _formatDialedNumber(_dialedNumber, isSip: isSip),
                                accountId: widget.authService.activeAccountId ?? '',
                                isVideo: true,
                                protocol: isSip ? 'SIP' : 'XMPP',
                              );
                            }
                          },
                        ),
                        _mainCallButton(callProvider),
                        _circleButton(
                          icon: Icons.backspace_rounded,
                          color: theme.colorScheme.outline,
                          onPressed: _onBackspace,
                          onLongPress: () => setState(() => _dialedNumber = ''),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyHistory(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history_rounded,
            size: 64,
            color: theme.colorScheme.outline.withValues(alpha: 0.1),
          ),
          const SizedBox(height: 16),
          Text(
            'No recent calls',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.outline.withValues(alpha: 0.5),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryItem(CallLog log, ThemeData theme) {
    final isMissed = log.status == CallStatus.missed;
    return Dismissible(
      key: Key(log.timestamp.toString() + log.jid),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: theme.colorScheme.error,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.delete_sweep_rounded, color: theme.colorScheme.onError),
      ),
      onDismissed: (_) {
        Provider.of<CallHistoryService>(context, listen: false).deleteLog(log);
        HapticFeedback.mediumImpact();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.05),
          ),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: CircleAvatar(
            backgroundColor: isMissed
                ? theme.colorScheme.error.withValues(alpha: 0.1)
                : theme.colorScheme.surfaceContainerHighest,
            child: Icon(
              log.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
              size: 20,
              color: isMissed ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          title: Text(
            widget.authService.getContactName(widget.authService.activeAccountId ?? '', log.jid),
            style: theme.textTheme.bodyLarge?.copyWith(
              color: isMissed ? theme.colorScheme.error : theme.colorScheme.onSurface,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Row(
            children: [
              Icon(
                log.direction == CallDirection.incoming
                    ? Icons.call_received_rounded
                    : Icons.call_made_rounded,
                size: 12,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 4),
              Text(
                '${log.timestamp.hour}:${log.timestamp.minute.toString().padLeft(2, '0')} • ${log.status.name.toUpperCase()}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
          trailing: log.duration != null
              ? Text(
                  '${log.duration!.inMinutes}:${(log.duration!.inSeconds % 60).toString().padLeft(2, '0')}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline.withValues(alpha: 0.6),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.call_rounded, size: 20),
                  onPressed: () {
                     setState(() => _dialedNumber = log.jid.split('@').first);
                  },
                ),
          onTap: () {
            setState(() => _dialedNumber = log.jid.split('@').first);
          },
        ),
      ),
    );
  }

  Widget _dialButton(String val, String sub, {VoidCallback? onLongPress}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onDial(val),
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              val,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                height: 1.0,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            if (sub.isNotEmpty)
              Text(
                sub,
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    VoidCallback? onLongPress,
  }) {
    return Material(
      color: color.withValues(alpha: 0.1),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        onLongPress: onLongPress,
        customBorder: const CircleBorder(),
        child: Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: 24),
        ),
      ),
    );
  }

  Widget _mainCallButton(CallProvider callProvider) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.green.shade500,
        boxShadow: [
          BoxShadow(
            color: Colors.green.withValues(alpha: 0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (_dialedNumber.isNotEmpty) {
              final isSip = callProvider.isSipRegistered;
              callProvider.startCall(
                _formatDialedNumber(_dialedNumber, isSip: isSip),
                accountId: widget.authService.activeAccountId ?? '',
                isVideo: false,
                protocol: isSip ? 'SIP' : 'XMPP',
              );
            }
          },
          customBorder: const CircleBorder(),
          child: Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            child: const Icon(Icons.call_rounded, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}