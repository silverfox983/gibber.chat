import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
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
  final TextEditingController _jidController = TextEditingController();
  final TextEditingController _passController = TextEditingController();

  bool _rememberMe = true;
  String? _selectedAccount;

  @override
  void dispose() {
    _jidController.dispose();
    _passController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Container(
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary),
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
                  padding: const EdgeInsets.symmetric(
                    vertical: 24.0,
                    horizontal: 24.0,
                  ),
                  physics: const ClampingScrollPhysics(),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildLogo(),
                      const SizedBox(height: 48),
                      _buildModernCard(child: _buildUnifiedForm(authService)),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.15),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Image.asset(
            'assets/logo.png',
            width: 84,
            height: 84,
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Gibber',
          style: TextStyle(
            fontSize: 42,
            letterSpacing: -1.5,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Secure Communication',
          style: TextStyle(
            fontSize: 16,
            color: Colors.white.withValues(alpha: 0.8),
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildUnifiedForm(AuthService authService) {
    final savedAccounts = authService.savedAccounts
        .where((a) => a.protocol == 'XMPP')
        .toList();

    return Column(
      children: [
        if (savedAccounts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 24.0),
            child: _buildAccountDropdown(savedAccounts),
          ),
        ],
        _buildTextField(
          _jidController,
          'Username',
          Icons.alternate_email,
        ),
        const SizedBox(height: 16),
        _buildTextField(
          _passController,
          'Password',
          Icons.lock_outline,
          obscureText: true,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            SizedBox(
              height: 24,
              width: 24,
              child: Checkbox(
                value: _rememberMe,
                onChanged: (val) => setState(() => _rememberMe = val ?? false),
                activeColor: Theme.of(context).colorScheme.secondary,
                checkColor: Theme.of(context).colorScheme.onSecondary,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Keep me logged in',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        if (authService.lastDiagnostic != null) ...[
          const SizedBox(height: 24),
          _buildDiagnostic(authService.lastDiagnostic!),
        ],
      ],
    );
  }

  Widget _buildAccountDropdown(List<SavedAccount> savedAccounts) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedAccount,
          hint: Text(
            'Switch Account',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          isExpanded: true,
          dropdownColor: Theme.of(context).colorScheme.surface,
          icon: const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Colors.white70,
          ),
          items: [
            DropdownMenuItem<String>(
              value: null,
              child: Text(
                'Select Account',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
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
                    fontWeight: FontWeight.w500,
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
              _jidController.clear();
              _passController.clear();
            } else if (val != null) {
              final acc = savedAccounts.firstWhere((a) => a.fullJid == val);
              _jidController.text = acc.fullJid;
            }
          },
        ),
      ),
    );
  }

  Widget _buildDiagnostic(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.error,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModernCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 30,
                offset: const Offset(0, 15),
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
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w500,
        fontSize: 16,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 14,
        ),
        prefixIcon: Icon(
          icon,
          color: Colors.white.withValues(alpha: 0.7),
          size: 22,
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.1),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: Colors.white.withValues(alpha: 0.5),
            width: 1.5,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 20,
          horizontal: 16,
        ),
      ),
    );
  }

  Widget _buildLoginButton(AuthService authService) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.secondary.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: authService.isConnecting
                ? null
                : () => _handleLogin(authService),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              foregroundColor: Theme.of(context).colorScheme.onSecondary,
              padding: const EdgeInsets.symmetric(vertical: 22),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              elevation: 0,
            ),
            child: authService.isConnecting
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 3,
                    ),
                  )
                : const Text(
                    'Sign In',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "Don't have an account?",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 14,
              ),
            ),
            TextButton(
              onPressed: () => context.go('/register'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.secondary,
              ),
              child: const Text(
                'Create Account',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLoginProgress(AuthService authService) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Establishing secure session...',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: authService.isConnecting ? null : 1,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.secondary,
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
      _showLoginError('Please enter your username.');
      return;
    }

    final validChars = RegExp(r'^[a-zA-Z0-9._\-@]+$');
    if (!validChars.hasMatch(input)) {
      _showLoginError(
        'Username contains invalid characters. Only letters, numbers, dots, hyphens, and underscores are allowed.',
      );
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
      _showLoginError('Please enter a valid username.');
      return;
    }

    if (domain.isEmpty) {
      domain = 'gibberapp.online';
    }

    if (_passController.text.isEmpty) {
      _showLoginError('Please enter your password.');
      return;
    }

    final port = kIsWeb ? 443 : 5222;

    try {
      await authService.connectXmpp(
        user: user,
        domain: domain,
        pass: _passController.text,
        port: port,
      ).timeout(const Duration(seconds: 30));

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

      if (mounted && widget.isAddingAccount) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account Added Successfully!')),
        );
        Navigator.pop(context);
      }
    } on TimeoutException {
      if (mounted) {
        _showLoginError(
          'Connection timed out. The server may be unreachable or your network may be slow. Please try again.',
        );
      }
    } catch (e) {
      if (mounted) {
        final errorStr = e.toString();
        final bool isSocketError =
            errorStr.contains('SocketException') ||
            errorStr.contains('Connection refused') ||
            errorStr.contains('Connection timed out') ||
            errorStr.contains('No route to host');
        final bool isTlsError =
            errorStr.contains('HandshakeException') ||
            errorStr.contains('CERTIFICATE_VERIFY_FAILED') ||
            errorStr.contains('TLS');
        final bool isAuthError =
            errorStr.contains('Authentication failed') ||
            errorStr.contains('not-authorized') ||
            errorStr.contains('sasl');

        String errorMessage = errorStr.replaceAll('Exception: ', '');
        String actionHint = '';

        if (isSocketError) {
          errorMessage =
              'Could not reach the server. Please check your network connection.';
          actionHint = ' Check your internet connection and try again.';
        } else if (isTlsError) {
          errorMessage =
              'Secure connection failed. Server certificate could not be verified.';
          actionHint = ' This may be a server configuration issue.';
        } else if (isAuthError) {
          errorMessage =
              'Authentication failed. Please check your username and password.';
          actionHint = ' Make sure your credentials are correct.';
        } else if (errorStr.contains('Null check')) {
          errorMessage = 'Connection failed unexpectedly.';
        } else if (errorStr.contains('forcefully closed') ||
            errorStr.contains('Connection closed')) {
          errorMessage =
              'The server closed the connection before login completed.';
          actionHint = ' The server may not support this client. Try a different port.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Login failed: $errorMessage$actionHint',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 12),
            backgroundColor: Theme.of(context).colorScheme.error,
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: () => _handleLogin(authService),
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
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.white,
              size: 20,
            ),
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
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}