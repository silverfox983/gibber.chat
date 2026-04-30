import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../models/chat_models.dart';
import '../services/registration_service.dart';

class LoginScreen extends StatefulWidget {
  final bool isAddingAccount;
  const LoginScreen({super.key, this.isAddingAccount = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _jidController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '5222');
  final TextEditingController _hostController = TextEditingController();

  bool _showAdvanced = false;
  bool _rememberMe = true;
  String? _selectedAccount;

  @override
  void dispose() {
    _jidController.dispose();
    _passController.dispose();
    _portController.dispose();
    _hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.primaryContainer,
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
                  padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 24.0),
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
          child: const Icon(
            Icons.forum_rounded,
            size: 64,
            color: Colors.white,
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
          'Secure XMPP Communication',
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
    final savedAccounts = authService.savedAccounts.where((a) => a.protocol == 'XMPP').toList();

    return Column(
      children: [
        if (savedAccounts.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 24.0),
            child: _buildAccountDropdown(savedAccounts),
          ),
        ],
        _buildTextField(_jidController, 'XMPP ID (user@domain)', Icons.alternate_email),
        const SizedBox(height: 16),
        _buildTextField(_passController, 'Password', Icons.lock_outline, obscureText: true),
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Keep me logged in',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildAdvancedToggle(),
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
            style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 14, fontWeight: FontWeight.w500),
          ),
          isExpanded: true,
          dropdownColor: Theme.of(context).colorScheme.surface,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70),
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
              _hostController.clear();
            } else if (val != null) {
              final acc = savedAccounts.firstWhere((a) => a.fullJid == val);
              _jidController.text = acc.fullJid;
              _portController.text = acc.port.toString();
              _hostController.text = acc.host ?? '';
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
          Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error, size: 20),
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

  Widget _buildAdvancedToggle() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _buildTextField(
                _portController,
                'Port',
                Icons.settings_ethernet,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: InkWell(
                onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _showAdvanced ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        color: Colors.white.withValues(alpha: 0.9),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _showAdvanced ? 'Hide Advanced' : 'Advanced',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9), 
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_showAdvanced) ...[
          const SizedBox(height: 16),
          _buildTextField(_hostController, 'Server Host (Optional)', Icons.dns),
        ],
      ],
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
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14),
        prefixIcon: Icon(icon, color: Colors.white.withValues(alpha: 0.7), size: 22),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.1),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.5), width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
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
                color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: authService.isConnecting ? null : () => _handleLogin(authService),
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
                    'Secure Connect',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 24),
        if (_selectedAccount == 'new' || _selectedAccount == null)
          TextButton.icon(
            onPressed: () async {
              final domain = _jidController.text.split('@').last;
              if (domain.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid JID domain first.')));
                return;
              }
              try {
                final regService = RegistrationService();
                final result = await regService.generateUserInvitation(domain);
                if (mounted) {
                  if (result != null && result.uri != null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Registration URI: \${result.uri}')));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Registration is not supported by this server.')));
                  }
                }
              } catch (e) {
                 if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Registration error: \$e')));
              }
            },
            icon: Icon(Icons.person_add_alt_1_rounded, color: Colors.white.withValues(alpha: 0.8), size: 20),
            label: Text(
              'Register on Server (XEP-0401)', 
              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 14, fontWeight: FontWeight.w600)
            ),
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
              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.secondary),
            ),
          ),
        ],
      ),
    );
  }

  void _handleLogin(AuthService authService) async {
    final input = _jidController.text.trim();

    if (input.isEmpty) {
      _showLoginError('Please enter your XMPP address.');
      return;
    }

    if (!input.contains('@') || input.split('@').length != 2 || input.split('@')[1].isEmpty) {
      _showLoginError('Invalid XMPP address. Use the format user@domain.com');
      return;
    }
    
    if (_passController.text.isEmpty) {
      _showLoginError('Please enter your password.');
      return;
    }
    
    final port = int.tryParse(_portController.text);
    if (port == null || port <= 0 || port > 65535) {
      _showLoginError('Invalid port number. Use a value between 1 and 65535.');
      return;
    }

    final parts = input.split('@');
    final user = parts[0];
    final domain = parts.length > 1 ? parts[1] : '';

    try {

      await authService.connectXmpp(
        user: user,
        domain: domain,
        pass: _passController.text,
        port: port,
        host: _hostController.text.isNotEmpty ? _hostController.text : null,
      );

      if (_rememberMe) {
        await authService.saveAccount(
          SavedAccount(
            user: user,
            domain: domain,
            port: port,
            host: _hostController.text.isNotEmpty ? _hostController.text : null,
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

        String errorMessage = errorStr.replaceAll('Exception: ', '');
        if (isSocketError) {
          errorMessage = 'Could not reach the server. Check the hostname and your network.';
        } else if (isTlsError) {
          errorMessage = 'Secure connection failed. Server certificate could not be verified.';
        } else if (errorStr.contains('Null check')) {
          errorMessage = 'Connection failed unexpectedly.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Login failed: $errorMessage',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 12),
            backgroundColor: Theme.of(context).colorScheme.error,
            action: SnackBarAction(
              label: 'PROBE',
              textColor: Colors.white,
              onPressed: () {
                final host = _hostController.text.isNotEmpty ? _hostController.text : domain;
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
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}