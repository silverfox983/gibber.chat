import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import '../services/registration_service.dart';
import '../services/backend_config.dart';
import '../models/registration_models.dart';
import '../models/chat_models.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _domainController = TextEditingController(text: 'gibberapp.online');

  bool _isRegistering = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _usernameError;
  String? _passwordError;
  String? _confirmError;
  String? _generalError;
  bool _usernameAvailable = false;
  bool _checkingUsername = false;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _domainController.dispose();
    super.dispose();
  }

  void _clearErrors() {
    setState(() {
      _usernameError = null;
      _passwordError = null;
      _confirmError = null;
      _generalError = null;
    });
  }

  bool _validate() {
    _clearErrors();
    bool valid = true;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;

    if (username.isEmpty) {
      setState(() => _usernameError = 'Username is required.');
      valid = false;
    } else if (username.length < 3) {
      setState(() => _usernameError = 'Username must be at least 3 characters.');
      valid = false;
    } else if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(username)) {
      setState(() => _usernameError = 'Only letters, numbers, dots, hyphens, and underscores.');
      valid = false;
    }

    if (password.isEmpty) {
      setState(() => _passwordError = 'Password is required.');
      valid = false;
    } else if (password.length < 8) {
      setState(() => _passwordError = 'Password must be at least 8 characters.');
      valid = false;
    }

    if (confirm.isEmpty) {
      setState(() => _confirmError = 'Please confirm your password.');
      valid = false;
    } else if (password != confirm) {
      setState(() => _confirmError = 'Passwords do not match.');
      valid = false;
    }

    return valid;
  }

  Future<void> _checkUsername() async {
    final username = _usernameController.text.trim();
    if (username.length < 3 || !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(username)) {
      if (mounted) setState(() { _usernameAvailable = false; _checkingUsername = false; });
      return;
    }

    setState(() { _checkingUsername = true; _usernameAvailable = false; });

    final backendConfig = Provider.of<BackendConfig>(context, listen: false);
    final available = await RegistrationService.checkUsernameAvailable(
      apiUrl: backendConfig.apiUrl,
      username: username,
      host: _domainController.text.trim(),
    );

    if (mounted) {
      setState(() {
        _checkingUsername = false;
        _usernameAvailable = available;
        if (!available) {
          _usernameError = 'Username is already taken.';
        } else {
          _usernameError = null;
        }
      });
    }
  }

  Future<void> _handleRegister() async {
    if (!_validate()) return;
    if (!_usernameAvailable && _domainController.text.trim() == 'gibberapp.online') {
      setState(() => _usernameError = 'Username is already taken.');
      return;
    }

    setState(() {
      _isRegistering = true;
      _generalError = null;
    });

    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final domain = _domainController.text.trim();
    final jid = '$username@$domain';

    final backendConfig = Provider.of<BackendConfig>(context, listen: false);
    final isGibberDomain = domain == 'gibberapp.online';

    RegistrationResult result;

    if (isGibberDomain) {
      result = await RegistrationService.registerViaBackend(
        apiUrl: backendConfig.apiUrl,
        username: username,
        password: password,
      );
    } else {
      if (kIsWeb) {
        if (mounted) {
          setState(() {
            _isRegistering = false;
            _generalError = 'Registration on external servers is not supported in browser. Use gibberapp.online or the desktop app.';
          });
        }
        return;
      }

      final success = await RegistrationService.registerAccountInBand(
        domain,
        username,
        password,
      );
      result = RegistrationResult(
        status: success ? RegistrationStatus.success : RegistrationStatus.networkError,
        jid: jid,
        message: success ? 'Registration successful' : 'Registration failed. The server may not support public registration.',
      );
    }

    if (!mounted) return;

    if (result.isOk) {
      final authService = Provider.of<AuthService>(context, listen: false);

      try {
        await authService.connectXmpp(
          user: username,
          domain: domain,
          pass: password,
          port: 5222,
          host: domain,
        );

        await authService.saveAccount(
          SavedAccount(
            user: username,
            domain: domain,
            port: 5222,
            host: domain,
            protocol: 'XMPP',
          ),
          password,
        );

        if (mounted) {
          context.go('/app');
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isRegistering = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Account created! Please sign in manually: $jid'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 8),
              action: SnackBarAction(
                label: 'SIGN IN',
                textColor: Colors.white,
                onPressed: () => context.go('/login'),
              ),
            ),
          );
          context.go('/login');
        }
      }
    } else {
      setState(() {
        _isRegistering = false;
        _generalError = result.message ?? 'Registration failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = isDark ? GibberTheme.eclipsePurple : GibberTheme.arcticBlue;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Container(
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLogo(),
                  const SizedBox(height: 32),
                  _buildCard(primary, isDark),
                  const SizedBox(height: 24),
                  _buildSignInLink(primary),
                ],
              ),
            ),
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
          child: Image.asset('assets/logo.png', width: 72, height: 72, fit: BoxFit.contain),
        ),
        const SizedBox(height: 20),
        const Text(
          'Create Account',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5),
        ),
        const SizedBox(height: 6),
        Text(
          'Sign up for free — no credit card needed',
          style: TextStyle(fontSize: 15, color: Colors.white.withValues(alpha: 0.8), fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _buildCard(Color primary, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 30, offset: const Offset(0, 15)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildUsernameField(primary),
              const SizedBox(height: 16),
              _buildDomainField(),
              const SizedBox(height: 16),
              _buildPasswordField(),
              const SizedBox(height: 16),
              _buildConfirmField(),
              if (_generalError != null) ...[
                const SizedBox(height: 16),
                _buildErrorBanner(_generalError!),
              ],
              const SizedBox(height: 24),
              _buildRegisterButton(primary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUsernameField(Color primary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _usernameController,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 16),
          decoration: InputDecoration(
            labelText: 'Username',
            labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14),
            prefixIcon: Icon(Icons.alternate_email, color: Colors.white.withValues(alpha: 0.7), size: 22),
            suffixIcon: _checkingUsername
                ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white.withValues(alpha: 0.7)))
                : _usernameAvailable && _usernameError == null && _usernameController.text.trim().length >= 3
                    ? Icon(Icons.check_circle_rounded, color: Colors.green.shade400, size: 22)
                    : null,
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.1),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.5), width: 1.5)),
            errorText: _usernameError,
            errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
            contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          ),
          onChanged: (_) {
            if (_usernameError != null) setState(() => _usernameError = null);
            _usernameAvailable = false;
            _debounceUsernameCheck();
          },
        ),
      ],
    );
  }

  Timer? _debounceTimer;

  void _debounceUsernameCheck() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (_domainController.text.trim() == 'gibberapp.online' && mounted) {
        _checkUsername();
      }
    });
  }

  Widget _buildDomainField() {
    return TextField(
      controller: _domainController,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 16),
      decoration: InputDecoration(
        labelText: 'Server Domain',
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14),
        prefixIcon: Icon(Icons.dns_rounded, color: Colors.white.withValues(alpha: 0.7), size: 22),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.1),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.5), width: 1.5)),
        helperText: 'gibberapp.online for instant signup. Other servers may not be supported.',
        helperStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
        contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      ),
      onChanged: (_) {
        setState(() { _usernameAvailable = false; _usernameError = null; });
      },
    );
  }

  Widget _buildPasswordField() {
    return TextField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 16),
      decoration: InputDecoration(
        labelText: 'Password',
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14),
        prefixIcon: Icon(Icons.lock_outline, color: Colors.white.withValues(alpha: 0.7), size: 22),
        suffixIcon: IconButton(
          icon: Icon(_obscurePassword ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: Colors.white.withValues(alpha: 0.7), size: 22),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.1),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.5), width: 1.5)),
        errorText: _passwordError,
        errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      ),
      onChanged: (_) {
        if (_passwordError != null) setState(() => _passwordError = null);
      },
    );
  }

  Widget _buildConfirmField() {
    return TextField(
      controller: _confirmPasswordController,
      obscureText: _obscureConfirm,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 16),
      decoration: InputDecoration(
        labelText: 'Confirm Password',
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 14),
        prefixIcon: Icon(Icons.lock_outline, color: Colors.white.withValues(alpha: 0.7), size: 22),
        suffixIcon: IconButton(
          icon: Icon(_obscureConfirm ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: Colors.white.withValues(alpha: 0.7), size: 22),
          onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.1),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.5), width: 1.5)),
        errorText: _confirmError,
        errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      ),
      onChanged: (_) {
        if (_confirmError != null) setState(() => _confirmError = null);
      },
      onSubmitted: (_) => _handleRegister(),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Widget _buildRegisterButton(Color primary) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: primary.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 10))],
      ),
      child: ElevatedButton(
        onPressed: _isRegistering ? null : _handleRegister,
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          elevation: 0,
        ),
        child: _isRegistering
            ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
            : const Text('Create Account', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
      ),
    );
  }

  Widget _buildSignInLink(Color primary) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Already have an account?',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => context.go('/login'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text(
              'Sign In',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}