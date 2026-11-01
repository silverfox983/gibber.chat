import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/join_intent.dart';
import '../services/auth_service.dart';
import '../services/gateway_service.dart';
import '../providers/chat_provider.dart';

enum JoinPhase { waitingForConnection, resolvingGateway, joining, missingGateway, failed, done }

/// Resumes a landing-page room join after the user authenticates: waits for
/// the XMPP connection, resolves the IRC gateway component, joins the room
/// and hands the user over to the chat shell.
class JoinRoomScreen extends StatefulWidget {
  final JoinIntent? intent;

  const JoinRoomScreen({super.key, required this.intent});

  @override
  State<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends State<JoinRoomScreen> {
  JoinPhase _phase = JoinPhase.waitingForConnection;
  String _statusText = 'Connecting to the network...';
  String? _errorDetail;
  String? _gatewayJid;
  bool _started = false;
  void Function()? _authListenerCleanup;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _authListenerCleanup?.call();
    super.dispose();
  }

  void _start() {
    if (_started) return;
    _started = true;
    final auth = Provider.of<AuthService>(context, listen: false);
    if (auth.xmppConnected) {
      _resolveGatewayAndJoin();
      return;
    }
    _phase = JoinPhase.waitingForConnection;
    void listener() {
      if (auth.xmppConnected && mounted) {
        _authListenerCleanup?.call();
        _authListenerCleanup = null;
        _resolveGatewayAndJoin();
      }
    }
    auth.addListener(listener);
    _authListenerCleanup = () => auth.removeListener(listener);
  }

  Future<void> _resolveGatewayAndJoin() async {
    if (!mounted) return;
    final auth = Provider.of<AuthService>(context, listen: false);
    if (widget.intent == null) {
      setState(() {
        _phase = JoinPhase.failed;
        _errorDetail = 'No room to join - pick one from the landing page.';
      });
      return;
    }
    setState(() {
      _phase = JoinPhase.resolvingGateway;
      _statusText = 'Finding the IRC bridge...';
    });

    final gateways = Provider.of<GatewayService>(context, listen: false);
    final response = await gateways.listGateways();
    final irc = response.gateways['irc'];
    if (irc == null ||
        !irc.enabled ||
        irc.componentJid.isEmpty ||
        irc.status == 'disabled') {
      if (!mounted) return;
      setState(() {
        _phase = JoinPhase.missingGateway;
        _statusText =
            'The IRC bridge is not active for this network right now.';
      });
      return;
    }
    _gatewayJid = irc.componentJid;

    setState(() {
      _phase = JoinPhase.joining;
      _statusText = 'Joining ${widget.intent!.channel} on ${widget.intent!.network ?? 'IRC'}...';
    });

    final nick = auth.getResolvedNickname(null);
    final roomJid = widget.intent!.roomJid(_gatewayJid!);
    final error = await auth.joinXmppRoom(roomJid, nick);

    if (!mounted) return;
    if (error != null) {
      setState(() {
        _phase = JoinPhase.failed;
        _errorDetail = error;
      });
      return;
    }

    Provider.of<ChatProvider>(context, listen: false).setActiveConversation(roomJid);
    if (!mounted) return;
    setState(() => _phase = JoinPhase.done);
    context.go('/app');
  }

  void _retry() {
    setState(() {
      _phase = JoinPhase.waitingForConnection;
      _errorDetail = null;
    });
    _resolveGatewayAndJoin();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final intent = widget.intent;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Join Room'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (intent != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.tag_rounded, color: primary),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          intent.channel,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (intent.network != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'via ${intent.network}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: primary, fontWeight: FontWeight.w600),
                    ),
                  ],
                  const SizedBox(height: 28),
                ],
                if (_phase == JoinPhase.missingGateway) ...[
                  Icon(Icons.extension_off_rounded,
                      size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    _statusText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Ask the server admin to enable the IRC gateway, or open your Connections panel to see available bridges.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: () => context.goNamed('connections'),
                    icon: const Icon(Icons.hub_rounded, size: 18),
                    label: const Text('Open Connections'),
                  ),
                ],
                if (_phase == JoinPhase.failed) ...[
                  Icon(Icons.error_outline_rounded,
                      size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    _statusText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  if (_errorDetail != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _errorDetail!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Try Again'),
                  ),
                  TextButton(
                    onPressed: () => context.go('/app'),
                    child: const Text('Back to chats'),
                  ),
                ],
                if (_phase == JoinPhase.waitingForConnection ||
                    _phase == JoinPhase.resolvingGateway ||
                    _phase == JoinPhase.joining) ...[
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 20),
                  Text(
                    _statusText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  if (_phase == JoinPhase.waitingForConnection) ...[
                    const SizedBox(height: 8),
                    Text(
                      'This can take a few seconds.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () => context.go('/app'),
                    child: const Text('Skip and browse chats'),
                  ),
                ],
                if (_phase == JoinPhase.done) ...[
                  Icon(Icons.check_circle_rounded, size: 48, color: primary),
                  const SizedBox(height: 12),
                  const Text('Joined! Opening the room...', textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}