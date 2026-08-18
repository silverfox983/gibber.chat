import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/registration_service.dart';
import '../services/jwt_token_service.dart';
import '../services/backend_config.dart';
import '../models/chat_models.dart';
import '../widgets/auth/auth_layout.dart';
import '../widgets/auth/auth_text_field.dart';
import '../widgets/auth/auth_button.dart';

class LoginScreen extends StatefulWidget {
  final bool isAddingAccount;
  const LoginScreen({super.key, this.isAddingAccount = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _jidController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  final FocusNode _passFocusNode = FocusNode();

  bool _rememberMe = true;
  bool _obscurePassword = true;
  bool _isConnecting = false;
  String? _errorMessage;
  String? _connectionStatus;
  String? _selectedAccount;

  @override
  void dispose() {
    _jidController.dispose();
    _passController.dispose();
    _passFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final form = _buildForm(authService, isDark);

    return AuthLayout(form: form);
  }

  Widget _buildForm(AuthService authService, bool isDark) {
    final savedAccounts = authService.savedAccounts
        .where((a) => a.protocol == 'XMPP')
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.isAddingAccount) ...[
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 8),
              Text(
                'Add Account',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF111827),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ] else ...[
          Text(
            'Welcome back',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: isDark ? Colors.white : const Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sign in to your Gibber account',
            style: TextStyle(
              fontSize: 15,
              color: isDark ? Colors.white54 : const Color(0xFF6B7280),
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 32),
        ],

        if (savedAccounts.isNotEmpty) ...[
          _buildAccountDropdown(savedAccounts, isDark),
          const SizedBox(height: 20),
          Divider(color: isDark ? Colors.white12 : const Color(0xFFE5E7EB)),
          const SizedBox(height: 20),
        ],

        AuthTextField(
          controller: _jidController,
          label: 'Username',
          prefixIcon: Icons.alternate_email_rounded,
          hint: 'Enter your username',
          domainSuffix: '@gibberapp.online',
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) {
            if (_errorMessage != null) setState(() => _errorMessage = null);
          },
          onSubmitted: () => _passFocusNode.requestFocus(),
        ),
        const SizedBox(height: 20),

        AuthTextField(
          controller: _passController,
          label: 'Password',
          prefixIcon: Icons.lock_outline_rounded,
          hint: 'Enter your password',
          obscureText: _obscurePassword,
          isPassword: true,
          onTogglePassword: () => setState(() => _obscurePassword = !_obscurePassword),
          focusNode: _passFocusNode,
          onChanged: (_) {
            if (_errorMessage != null) setState(() => _errorMessage = null);
          },
          onSubmitted: () => _handleLogin(authService),
        ),
        const SizedBox(height: 16),

        Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: _rememberMe,
                onChanged: (val) => setState(() => _rememberMe = val ?? true),
                activeColor: Theme.of(context).colorScheme.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() => _rememberMe = !_rememberMe),
              child: Text(
                'Keep me logged in',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : const Color(0xFF6B7280),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),

        if (_connectionStatus != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _connectionStatus!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          _buildErrorBanner(_errorMessage!, isDark),
        ],

        const SizedBox(height: 24),
        AuthButton(
          label: 'Sign In',
          isLoading: _isConnecting,
          onPressed: () => _handleLogin(authService),
        ),
        const SizedBox(height: 24),

        if (!widget.isAddingAccount) ...[
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "Don't have an account? ",
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white54 : const Color(0xFF6B7280),
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/register'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Create Account',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: () => _showLegalDialog(context, 'terms'),
                  style: TextButton.styleFrom(
                    foregroundColor: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Terms of Service',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                Text(
                  ' · ',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                  ),
                ),
                TextButton(
                  onPressed: () => _showLegalDialog(context, 'privacy'),
                  style: TextButton.styleFrom(
                    foregroundColor: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Privacy Policy',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAccountDropdown(List<SavedAccount> savedAccounts, bool isDark) {
    final borderColor = isDark ? Colors.white24 : const Color(0xFFE5E7EB);
    final surfaceColor = isDark ? const Color(0xFF1E293B) : const Color(0xFFF3F4F6);
    final textColor = isDark ? Colors.white : const Color(0xFF111827);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedAccount,
          hint: Text(
            'Switch Account',
            style: TextStyle(
              color: isDark ? Colors.white54 : const Color(0xFF6B7280),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          isExpanded: true,
          dropdownColor: surfaceColor,
          icon: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: isDark ? Colors.white54 : const Color(0xFF6B7280),
          ),
          items: [
            DropdownMenuItem<String>(
              value: null,
              child: Text(
                'Select Account',
                style: TextStyle(color: textColor, fontSize: 14),
              ),
            ),
            ...savedAccounts.map<DropdownMenuItem<String>>(
              (acc) => DropdownMenuItem<String>(
                value: acc.fullJid,
                child: Text(
                  acc.fullJid,
                  style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w500),
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
            setState(() => _selectedAccount = val);
            if (val == 'new') {
              _jidController.clear();
              _passController.clear();
            } else if (val != null) {
              final acc = savedAccounts.cast<SavedAccount?>().firstWhere(
                (a) => a?.fullJid == val,
                orElse: () => null,
              );
              if (acc != null) {
                _jidController.text = acc.user;
              }
            }
          },
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String message, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.error,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleLogin(AuthService authService) async {
    final input = _jidController.text.trim();

    if (input.isEmpty) {
      setState(() => _errorMessage = 'Please enter your username.');
      return;
    }

    final validChars = RegExp(r'^[a-zA-Z0-9._\-@]+$');
    if (!validChars.hasMatch(input)) {
      setState(() => _errorMessage = 'Username contains invalid characters. Only letters, numbers, dots, hyphens, and underscores are allowed.');
      return;
    }

    String user;
    String domain;

    if (input.contains('@')) {
      final parts = input.split('@');
      user = parts[0];
      domain = parts.length > 1 ? parts[1] : '';
    } else {
      user = input;
      domain = 'gibberapp.online';
    }

    if (user.isEmpty) {
      setState(() => _errorMessage = 'Please enter a valid username.');
      return;
    }

    if (domain.isEmpty) {
      domain = 'gibberapp.online';
    }

    if (_passController.text.isEmpty) {
      setState(() => _errorMessage = 'Please enter your password.');
      return;
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    final port = kIsWeb ? 443 : 5222;

    setState(() {
      _errorMessage = null;
      _connectionStatus = 'Connecting to $domain...';
    });

    try {
      final backendConfig = Provider.of<BackendConfig>(context, listen: false);

      setState(() => _connectionStatus = 'Authenticating...');

      await authService.connectXmpp(
        user: user,
        domain: domain,
        pass: _passController.text,
        port: port,
      ).timeout(const Duration(seconds: 30));

      setState(() => _connectionStatus = 'Loading your data...');

      try {
        final loginResult = await RegistrationService.loginWithJwt(
          apiUrl: backendConfig.apiUrl,
          username: user,
          password: _passController.text,
          host: domain,
        );
        if (loginResult.accessToken != null) {
          final jwtService = JwtTokenService();
          await jwtService.saveTokens(
            accessToken: loginResult.accessToken!,
            refreshToken: loginResult.refreshToken,
            jid: loginResult.jid,
            apiUrl: backendConfig.apiUrl,
          );
        }
      } catch (_) {}

      setState(() => _connectionStatus = 'Almost ready...');

      if (_rememberMe) {
        await authService.saveAccount(
          SavedAccount(
            user: user,
            domain: domain,
            port: port,
            protocol: 'XMPP',
          ),
          _passController.text,
        );
      }

      setState(() => _connectionStatus = null);

      if (mounted && widget.isAddingAccount) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account Added Successfully!')),
        );
        Navigator.pop(context);
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = 'Connection timed out. The server may be unreachable or your network may be slow.';
        });
      }
    } catch (e) {
      if (mounted) {
        final errorStr = e.toString();
        String errorMessage;

        if (errorStr.contains('SocketException') ||
            errorStr.contains('Connection refused') ||
            errorStr.contains('Connection timed out') ||
            errorStr.contains('No route to host') ||
            errorStr.contains('WebSocketChannelException') ||
            errorStr.contains('WebSocketException')) {
          errorMessage = 'Could not reach the server. Please check your network connection.';
        } else if (errorStr.contains('HandshakeException') ||
            errorStr.contains('CERTIFICATE_VERIFY_FAILED') ||
            errorStr.contains('TLS')) {
          errorMessage = 'Secure connection failed. Server certificate could not be verified.';
        } else if (errorStr.contains('Authentication failed') ||
            errorStr.contains('not-authorized') ||
            errorStr.contains('sasl')) {
          errorMessage = 'Invalid username or password.';
        } else if (errorStr.contains('forcefully closed') ||
            errorStr.contains('Connection closed') ||
            errorStr.contains('Socket has been destroyed')) {
          errorMessage = 'Connection lost during login. Please try again.';
        } else if (errorStr.contains('All connection paths') ||
            errorStr.contains('probe') ||
            errorStr.contains('Socket closed unexpectedly') ||
            errorStr.contains('All connection paths to')) {
          errorMessage = 'Could not connect to the server. Please check your network and try again.';
        } else {
          errorMessage = errorStr.replaceAll('Exception: ', '');
        }

        setState(() {
          _isConnecting = false;
          _errorMessage = errorMessage;
          _connectionStatus = null;
        });
      }
    }
  }

  void _showLegalDialog(BuildContext context, String type) {
    final title = type == 'terms' ? 'Terms of Service' : 'Privacy Policy';
    final content = type == 'terms'
        ? _termsContent
        : _privacyContent;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(
            content,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static const String _termsContent = '''
Terms of Service

Last updated: August 2026

1. Acceptance of Terms
By using Gibber, you agree to these terms. If you do not agree, do not use the service.

2. Use of Service
Gibber provides encrypted XMPP-based communication services. You agree to use the service lawfully and not to send spam, malware, or harmful content.

3. Privacy
Your messages are end-to-end encrypted. We do not have access to the content of your communications. See our Privacy Policy for details.

4. Account Responsibility
You are responsible for keeping your password secure and for all activity under your account.

5. Service Availability
We strive for uptime but do not guarantee uninterrupted service. We reserve the right to modify or discontinue service with reasonable notice.

6. Limitation of Liability
Gibber is provided "as is" without warranties. We are not liable for damages arising from use of the service.

7. Changes to Terms
We may update these terms. Continued use after changes constitutes acceptance.

Contact: admin@gibberapp.online
''';

  static const String _privacyContent = '''
Privacy Policy

Last updated: August 2026

1. Information We Collect
We collect minimal information necessary to provide the service: your XMPP username (JID) and authentication credentials. We do not require a phone number or email.

2. How We Use Information
- Authentication: Your credentials are used solely to authenticate with the XMPP server.
- Service operation: Minimal metadata (connection timestamps, IP addresses) may be logged for operational purposes.
- Payments: If you subscribe, payment processing is handled by third-party providers (Stripe, BTCPay Server). We do not store payment card details.

3. End-to-End Encryption
All messages are encrypted using OMEMO or OpenPGP. We cannot read, access, or decrypt your messages. Group chat encryption keys are distributed among participants.

4. Data Retention
- Account data: Retained until you delete your account.
- Message archives (MAM): Stored encrypted on the server per your preference and applicable server settings.
- Logs: Connection metadata retained for up to 30 days.

5. Third-Party Services
- Federation: Messages to/from other XMPP servers pass through their servers, governed by their privacy policies.
- Gateway transports (Telegram, Discord, etc.): When you use gateway bridges, your messages are processed by those third-party services.

6. Your Rights
You may request deletion of your account and all associated data at any time by contacting admin@gibberapp.online.

7. Security
We use industry-standard encryption (TLS, OMEMO) to protect data in transit and at rest.

8. Contact
admin@gibberapp.online
''';
}