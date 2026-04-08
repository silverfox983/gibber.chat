import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../models/chat_models.dart';

class LoginScreen extends StatefulWidget {
  final bool isAddingAccount;
  const LoginScreen({super.key, this.isAddingAccount = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _unifiedAddress = TextEditingController(
    text: 'your-username@domain.com',
  );
  final TextEditingController _xmppPass = TextEditingController(
    text: 'your-password',
  );
  final TextEditingController _xmppPort = TextEditingController(text: '5222');
  final TextEditingController _xmppHost = TextEditingController();

  final TextEditingController _ircNick = TextEditingController(
    text: 'flutteruser',
  );
  final TextEditingController _ircChannel = TextEditingController(
    text: '#flutter',
  );

  ConnectionProtocol _detectedProtocol = ConnectionProtocol.xmpp;
  bool _showAdvanced = false;
  bool _rememberMe = true;
  String? _selectedAccount;

  @override
  void initState() {
    super.initState();
    _unifiedAddress.addListener(_onAddressChanged);
  }

  @override
  void dispose() {
    _unifiedAddress.removeListener(_onAddressChanged);
    _unifiedAddress.dispose();
    _xmppPass.dispose();
    _xmppPort.dispose();
    _xmppHost.dispose();
    _ircNick.dispose();
    _ircChannel.dispose();
    super.dispose();
  }

  void _onAddressChanged() {
    final protocol = AuthService.detectProtocol(_unifiedAddress.text);
    if (protocol != ConnectionProtocol.none && protocol != _detectedProtocol) {
      setState(() {
        _detectedProtocol = protocol;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    try {
      final authService = Provider.of<AuthService>(context);

      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _detectedProtocol == ConnectionProtocol.discord
                  ? [
                      const Color(0xFF5865F2),
                      const Color(0xFF404EED),
                    ] // Discord Blurple
                  : [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.secondary,
                    ],
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: [
                if (widget.isAddingAccount)
                  Positioned(
                    top: 16,
                    left: 16,
                    child: IconButton(
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 24.0),
                    physics: const ClampingScrollPhysics(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.forum_rounded,
                            size: 80,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Gibber',
                            style: TextStyle(
                              fontSize: 36,
                              letterSpacing: -1,
                              fontWeight: FontWeight.w900,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Multi-protocol Chat Client',
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 48),
                          _buildModernCard(child: _buildUnifiedForm()),
                          const SizedBox(height: 32),
                          _buildLoginButton(authService),
                          if (authService.isConnecting) ...[
                            const SizedBox(height: 16),
                            _buildLoginProgress(authService),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      return Scaffold(
        backgroundColor: Colors.greenAccent,
        body: Center(
          child: Text(
            'LOGIN SCREEN CRASH: $e',
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }
  }

  Widget _buildUnifiedForm() {
    final authService = Provider.of<AuthService>(context);
    final savedAccounts = authService.savedAccounts;

    String label = 'XMPP ID (user@domain)';
    IconData icon = Icons.alternate_email;
    if (_detectedProtocol == ConnectionProtocol.irc) {
      label = 'IRC Server';
      icon = Icons.dns;
    } else if (_detectedProtocol == ConnectionProtocol.discord) {
      label = 'Discord Bot Token';
      icon = Icons.token;
    }

    return Column(
      children: [
        if (savedAccounts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 16.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: DropdownButton<String>(
                value: _selectedAccount,
                hint: Text(
                  'Switch Account',
                  style: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7), fontSize: 13),
                ),
                underline: const SizedBox(),
                isExpanded: true,
                dropdownColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
                icon: const Icon(Icons.account_circle, color: Colors.white70),
                items: [
                  DropdownMenuItem<String>(
                    value: null,
                    child: Text(
                      'Select Account',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
                    ),
                  ),
                  ...savedAccounts.map<DropdownMenuItem<String>>(
                    (acc) => DropdownMenuItem<String>(
                      value: acc.fullJid,
                      child: Text(
                        acc.fullJid,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  DropdownMenuItem<String>(
                    value: 'new',
                    child: Text(
                      '+ Add New Account',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
                onChanged: (val) {
                  setState(() {
                    _selectedAccount = val;
                  });
                  if (val == 'new') {
                    _unifiedAddress.clear();
                    _xmppPass.clear();
                    _xmppHost.clear();
                    setState(() {
                      _detectedProtocol = ConnectionProtocol.xmpp;
                    });
                  } else if (val != null) {
                    final acc = savedAccounts.firstWhere(
                      (a) => a.fullJid == val,
                    );
                    _unifiedAddress.text = acc.fullJid;
                    _xmppPort.text = acc.port.toString();
                    _xmppHost.text = acc.host ?? '';
                    // Update protocol based on saved account
                    ConnectionProtocol detectedProtocol;
                    if (acc.protocol == 'Discord') {
                      detectedProtocol = ConnectionProtocol.discord;
                    } else if (acc.protocol == 'IRC') {
                      detectedProtocol = ConnectionProtocol.irc;
                    } else {
                      detectedProtocol = ConnectionProtocol.xmpp;
                    }
                    if (detectedProtocol != _detectedProtocol) {
                      setState(() {
                        _detectedProtocol = detectedProtocol;
                      });
                    }
                  }
                },
              ),
            ),
          ),
        ],
        _buildTextField(_unifiedAddress, label, icon),
        const SizedBox(height: 16),
        if (_detectedProtocol == ConnectionProtocol.xmpp) ...[
          _buildTextField(_xmppPass, 'Password', Icons.lock, obscureText: true),
          const SizedBox(height: 16),
          const SizedBox(height: 8),
          Row(
            children: [
              Checkbox(
                value: _rememberMe,
                onChanged: (val) => setState(() => _rememberMe = val ?? false),
                activeColor: Theme.of(context).colorScheme.secondary,
                checkColor: Theme.of(context).colorScheme.onSecondary,
                side: BorderSide(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)),
              ),
              Text(
                'Keep me logged in',
                style: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7), fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildAdvancedToggle(),
        ] else if (_detectedProtocol == ConnectionProtocol.irc) ...[
          _buildTextField(_ircNick, 'Nickname', Icons.person),
          const SizedBox(height: 16),
          _buildTextField(_ircChannel, 'Channel', Icons.tag),
        ] else if (_detectedProtocol == ConnectionProtocol.discord) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blueAccent.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.blueAccent.withValues(alpha: 0.3),
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.amber),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Self-Bot Warning',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  'Using user tokens (self-bots) is against Discord\'s Terms of Service and may result in account termination. Procceed at your own risk.',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Ensure "Message Content Intent" is enabled for bot tokens.',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
          ),
        ] else ...[
          const Text(
            'Enter address to detect protocol',
            style: TextStyle(color: Colors.white70),
          ),
        ],
        if (authService.lastDiagnostic != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: Colors.redAccent.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    authService.lastDiagnostic!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAdvancedToggle() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _buildTextField(
                _xmppPort,
                'Port',
                Icons.settings_ethernet,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: TextButton.icon(
                onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                icon: Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white70,
                ),
                label: Text(
                  _showAdvanced ? 'Hide Advanced' : 'Advanced Settings',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
        if (_showAdvanced) ...[
          const SizedBox(height: 16),
          _buildTextField(_xmppHost, 'Server Host (Optional)', Icons.dns),
        ],
      ],
    );
  }

  Widget _buildModernCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool obscureText = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.normal,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
        prefixIcon: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 20),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildLoginButton(AuthService authService) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: authService.isConnecting
            ? null
            : () => _handleLogin(authService),
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
          padding: const EdgeInsets.symmetric(vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          elevation: 0,
        ),
        child: authService.isConnecting
            ? const SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              )
            : const Text(
                'Connect Now',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
      ),
    );
  }

  Widget _buildLoginProgress(AuthService authService) {
    final progressColor = _detectedProtocol == ConnectionProtocol.discord
        ? const Color(0xFF5865F2)
        : Theme.of(context).colorScheme.secondary;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Logging in...',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: authService.isConnecting ? null : 1,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(progressColor),
            ),
          ),
        ],
      ),
    );
  }

  void _handleLogin(AuthService authService) async {
    final input = _unifiedAddress.text.trim();

    // Input validation
    if (input.isEmpty ||
        input == 'your-username@domain.com') {
      _showLoginError('Please enter your account address.');
      return;
    }

    if (_detectedProtocol == ConnectionProtocol.xmpp) {
      if (!input.contains('@') || input.split('@').length != 2 || input.split('@')[1].isEmpty) {
        _showLoginError('Invalid XMPP address. Use the format user@domain.com');
        return;
      }
      if (_xmppPass.text.isEmpty || _xmppPass.text == 'your-password') {
        _showLoginError('Please enter your password.');
        return;
      }
      final port = int.tryParse(_xmppPort.text);
      if (port == null || port <= 0 || port > 65535) {
        _showLoginError('Invalid port number. Use a value between 1 and 65535.');
        return;
      }
    }

    try {
      if (_detectedProtocol == ConnectionProtocol.xmpp) {
        final parts = input.split('@');
        final user = parts[0];
        final domain = parts.length > 1 ? parts[1] : '';

        await authService.connectXmpp(
          user: user,
          domain: domain,
          pass: _xmppPass.text,
          port: int.parse(_xmppPort.text),
          host: _xmppHost.text.isNotEmpty ? _xmppHost.text : null,
        );

        if (_rememberMe) {
          await authService.saveAccount(
            SavedAccount(
              user: user,
              domain: domain,
              port: int.parse(_xmppPort.text),
              host: _xmppHost.text.isNotEmpty ? _xmppHost.text : null,
              protocol: 'XMPP',
            ),
            _xmppPass.text,
          );
        }
      } else if (_detectedProtocol == ConnectionProtocol.irc) {
        if (_ircNick.text.trim().isEmpty) {
          _showLoginError('Please enter a nickname for IRC.');
          return;
        }
        await authService.connectIrc(
          host: input,
          port: 6667,
          nick: _ircNick.text,
          channel: _ircChannel.text,
        );

        if (_rememberMe) {
          await authService.saveAccount(
            SavedAccount(
              user: _ircNick.text,
              domain: input, // IRC host
              port: 6667,
              protocol: 'IRC',
              autoJoinChannels: _ircChannel.text.isNotEmpty
                  ? [_ircChannel.text]
                  : [],
            ),
            '',
          );
        }
      } else if (_detectedProtocol == ConnectionProtocol.discord) {
        String token = input.trim();
        // If the user selected a saved account, the text is "handle@discord.com"
        // We need the actual token from secure storage.
        if (token.toLowerCase().endsWith('@discord.com')) {
          final handle = token.split('@').first;
          final savedToken = await authService.getSavedDiscordToken(handle);
          if (savedToken != null) {
            token = savedToken;
          }
        }
        await authService.connectDiscord(token, rememberMe: _rememberMe);
      }

      if (mounted && widget.isAddingAccount) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account Added Successfully!')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        final errorStr = e.toString();
        final bool isJabb3rError =
            errorStr.contains('jabb3r.org') ||
            errorStr.contains('hot-chilli.net');
        final bool isDiscordError =
            errorStr.toLowerCase().contains('discord') ||
            errorStr.contains('4014') ||
            errorStr.contains('4004') ||
            errorStr.contains('unauthorized') ||
            errorStr.contains('handshake');
        final bool isSocketError =
            errorStr.contains('SocketException') ||
            errorStr.contains('Connection refused') ||
            errorStr.contains('Connection timed out') ||
            errorStr.contains('No route to host') ||
            errorStr.contains('Network is unreachable');
        final bool isTlsError =
            errorStr.contains('HandshakeException') ||
            errorStr.contains('CERTIFICATE_VERIFY_FAILED') ||
            errorStr.contains('TLS') ||
            errorStr.contains('SSL');

        String errorMessage = errorStr.replaceAll('Exception: ', '');
        if (isDiscordError) {
          if (errorStr.contains('4004')) {
            errorMessage =
                'Discord: Invalid token. Ensure you\'re using a BOT token from the Discord Developer Portal.';
          } else if (errorStr.contains('4014')) {
            errorMessage =
                'Discord: Disallowed Intent. Enable "Message Content Intent" in Discord Developer Portal.';
          } else if (errorStr.contains('unauthorized')) {
            errorMessage =
                'Discord: Unauthorized. Use a valid BOT token (not a user token).';
          } else {
            errorMessage = 'Discord login failed: $errorMessage';
          }
        } else if (isSocketError) {
          errorMessage = 'Could not reach the server. Check the hostname, port, and your network connection.';
        } else if (isTlsError) {
          errorMessage = 'Secure connection failed. The server\'s certificate could not be verified.';
        } else if (errorStr.contains('Null check')) {
          errorMessage = 'Connection failed unexpectedly. The server may be unreachable or returned an invalid response.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Login failed: $errorMessage',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            duration: Duration(seconds: isDiscordError ? 15 : 12),
            backgroundColor: isDiscordError
                ? Colors.indigo
                : isSocketError || isTlsError
                    ? Colors.red.shade800
                    : null,
            action: isJabb3rError
                ? SnackBarAction(
                    label: 'AUTO-FIX',
                    textColor: Colors.white,
                    onPressed: () {
                      setState(() {
                        _xmppHost.text = 'jabber.hot-chilli.net';
                        _xmppPort.text = '5222';
                        _showAdvanced = true;
                      });
                    },
                  )
                : isDiscordError
                ? SnackBarAction(
                    label: 'HELP',
                    textColor: Colors.white,
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Discord Bot Setup'),
                          content: const SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '1. Go to https://discord.com/developers/applications',
                                ),
                                SizedBox(height: 8),
                                Text('2. Create a New Application'),
                                SizedBox(height: 8),
                                Text('3. Go to "Bot" section on the left'),
                                SizedBox(height: 8),
                                Text(
                                  '4. Click "Reset Token" to get your bot token',
                                ),
                                SizedBox(height: 8),
                                Text(
                                  '5. Enable "Message Content Intent" in "Bot" > "Privileged Gateway Intents"',
                                ),
                                SizedBox(height: 8),
                                Text('6. Copy the token and paste it here'),
                              ],
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('OK'),
                            ),
                          ],
                        ),
                      );
                    },
                  )
                : SnackBarAction(
                    label: 'PROBE',
                    textColor: Colors.white,
                    onPressed: () {
                      final host = _xmppHost.text.isNotEmpty
                          ? _xmppHost.text
                          : _unifiedAddress.text.split('@').last;
                      final port = int.tryParse(_xmppPort.text) ?? 5222;
                      authService.testSocketConnection(host, port);
                    },
                  ),
          ),
        );
      }
    }
  }

  void _showLoginError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.orange.shade800,
        duration: const Duration(seconds: 5),
      ),
    );
  }
}
