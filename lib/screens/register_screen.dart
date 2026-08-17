import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import '../services/registration_service.dart';
import '../services/backend_config.dart';
import '../services/jwt_token_service.dart';
import '../models/registration_models.dart';
import '../models/chat_models.dart';
import '../widgets/auth/auth_layout.dart';
import '../widgets/auth/auth_text_field.dart';
import '../widgets/auth/auth_button.dart';
import '../widgets/auth/password_strength_bar.dart';
import '../widgets/turnstile_web_widget_stub.dart'
    if (dart.library.html) '../widgets/turnstile_web_widget.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final FocusNode _passFocusNode = FocusNode();
  final FocusNode _confirmFocusNode = FocusNode();

  bool _isRegistering = false;
  String? _registerStatus;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _usernameError;
  String? _passwordError;
  String? _confirmError;
  String? _generalError;
  bool _usernameAvailable = false;
  bool _checkingUsername = false;
  bool _termsAccepted = false;
  String? _captchaToken;

  static const String _turnstileSiteKey = '0x4AAAAAAEPu7u6fV3cTv5Q6';

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _passFocusNode.dispose();
    _confirmFocusNode.dispose();
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
      _usernameError = 'Username is required.';
      valid = false;
    } else if (username.length < 3) {
      _usernameError = 'Username must be at least 3 characters.';
      valid = false;
    } else if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(username)) {
      _usernameError = 'Only letters, numbers, dots, hyphens, and underscores.';
      valid = false;
    }

    if (password.isEmpty) {
      _passwordError = 'Password is required.';
      valid = false;
    } else if (password.length < 8) {
      _passwordError = 'Password must be at least 8 characters.';
      valid = false;
    } else {
      final hasLower = password.contains(RegExp(r'[a-z]'));
      final hasUpper = password.contains(RegExp(r'[A-Z]'));
      final hasDigit = password.contains(RegExp(r'[0-9]'));
      if (!hasLower || !hasUpper || !hasDigit) {
        _passwordError = 'Password must contain uppercase, lowercase, and numbers.';
        valid = false;
      }
    }

    if (confirm.isEmpty) {
      _confirmError = 'Please confirm your password.';
      valid = false;
    } else if (password != confirm) {
      _confirmError = 'Passwords do not match.';
      valid = false;
    }

    if (!_termsAccepted) {
      _generalError = 'You must accept the Terms of Service.';
      valid = false;
    }

    return valid;
  }

  Future<bool> _checkUsername() async {
    final username = _usernameController.text.trim();
    if (username.length < 3 || !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(username)) {
      if (mounted) setState(() { _usernameAvailable = false; _checkingUsername = false; });
      return false;
    }

    setState(() { _checkingUsername = true; _usernameAvailable = false; });

    final backendConfig = Provider.of<BackendConfig>(context, listen: false);
    final available = await RegistrationService.checkUsernameAvailable(
      apiUrl: backendConfig.apiUrl,
      username: username,
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
    return available;
  }

  Timer? _debounceTimer;

  void _debounceUsernameCheck() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _checkUsername();
    });
  }

  Future<void> _handleRegister() async {
    if (!_validate()) return;
    final backendConfig = Provider.of<BackendConfig>(context, listen: false);
    if (kIsWeb && backendConfig.captchaEnabled && _captchaToken == null) {
      setState(() => _generalError = 'Please complete the captcha verification.');
      return;
    }

    if (_checkingUsername) {
      _debounceTimer?.cancel();
      await _checkUsername();
      if (!mounted) return;
    }

    if (!_usernameAvailable) {
      setState(() => _usernameError = 'Username is already taken.');
      return;
    }

    setState(() {
      _isRegistering = true;
      _generalError = null;
      _registerStatus = 'Creating account...';
    });

    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    const domain = 'gibberapp.online';

    final result = await RegistrationService.registerViaBackend(
      apiUrl: backendConfig.apiUrl,
      username: username,
      password: password,
      captchaToken: _captchaToken,
    );

    if (!mounted) return;

    if (result.isOk) {
      setState(() => _registerStatus = 'Account created. Connecting...');

      if (result.accessToken != null) {
        final jwtService = JwtTokenService();
        await jwtService.saveTokens(
          accessToken: result.accessToken!,
          refreshToken: result.refreshToken,
          jid: result.jid,
          apiUrl: backendConfig.apiUrl,
        );
      }

      final authService = Provider.of<AuthService>(context, listen: false);

      try {
        await authService.connectXmpp(
          user: username,
          domain: domain,
          pass: password,
          port: kIsWeb ? 443 : 5222,
        );

        await authService.saveAccount(
          SavedAccount(
            user: username,
            domain: domain,
            port: kIsWeb ? 443 : 5222,
            protocol: 'XMPP',
          ),
          password,
        );

        if (mounted) {
          setState(() => _registerStatus = 'Connected. Redirecting...');
          context.go('/app');
        }
      } catch (e) {
        if (mounted) {
          setState(() { _isRegistering = false; _registerStatus = null; });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Account created! Please sign in manually.'),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 6),
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
        _registerStatus = null;
        if (result.status == RegistrationStatus.captchaFailed) {
          _captchaToken = null;
        }
        _generalError = result.message ?? 'Registration failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backendConfig = Provider.of<BackendConfig>(context);
    final showCaptcha = kIsWeb && backendConfig.captchaEnabled;

    final form = _buildForm(isDark, showCaptcha);

    return AuthLayout(form: form);
  }

  Widget _buildForm(bool isDark, bool showCaptcha) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Create your account',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: isDark ? Colors.white : const Color(0xFF111827),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Sign up for free — no credit card needed',
          style: TextStyle(
            fontSize: 15,
            color: isDark ? Colors.white54 : const Color(0xFF6B7280),
            fontWeight: FontWeight.w400,
          ),
        ),
        const SizedBox(height: 32),

        AuthTextField(
          controller: _usernameController,
          label: 'Username',
          prefixIcon: Icons.alternate_email_rounded,
          hint: 'Choose a username',
          domainSuffix: '@gibberapp.online',
          errorText: _usernameError,
          isLoading: _checkingUsername,
          showSuccess: _usernameAvailable && _usernameError == null && _usernameController.text.trim().length >= 3,
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) {
            if (_usernameError != null) setState(() => _usernameError = null);
            _usernameAvailable = false;
            _debounceUsernameCheck();
          },
          onSubmitted: () => _passFocusNode.requestFocus(),
        ),
        const SizedBox(height: 20),

        AuthTextField(
          controller: _passwordController,
          label: 'Password',
          prefixIcon: Icons.lock_outline_rounded,
          hint: 'At least 8 characters with uppercase, lowercase, and numbers',
          obscureText: _obscurePassword,
          isPassword: true,
          errorText: _passwordError,
          focusNode: _passFocusNode,
          onTogglePassword: () => setState(() => _obscurePassword = !_obscurePassword),
          onChanged: (_) {
            if (_passwordError != null) setState(() => _passwordError = null);
          },
          onSubmitted: () => _confirmFocusNode.requestFocus(),
        ),
        PasswordStrengthBar(password: _passwordController.text),
        const SizedBox(height: 20),

        AuthTextField(
          controller: _confirmPasswordController,
          label: 'Confirm Password',
          prefixIcon: Icons.lock_outline_rounded,
          hint: 'Re-enter your password',
          obscureText: _obscureConfirm,
          isPassword: true,
          errorText: _confirmError,
          focusNode: _confirmFocusNode,
          onTogglePassword: () => setState(() => _obscureConfirm = !_obscureConfirm),
          onChanged: (_) {
            if (_confirmError != null) setState(() => _confirmError = null);
          },
          onSubmitted: () => _handleRegister(),
        ),
        const SizedBox(height: 16),

        if (showCaptcha) ...[
          Center(
            child: TurnstileWebWidget(
              siteKey: _turnstileSiteKey,
              theme: Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light',
              action: 'signup',
              onTokenReceived: (token) {
                setState(() => _captchaToken = token);
              },
              onTokenExpired: () {
                setState(() => _captchaToken = null);
              },
              onError: () {
                setState(() => _generalError = 'Captcha verification failed. Please try again.');
              },
            ),
          ),
          if (_captchaToken == null) ...[
            const SizedBox(height: 4),
            Text(
              'Verifying you are human...',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white38 : const Color(0xFF9CA3AF),
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 8),
        ],

        Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: _termsAccepted,
                onChanged: (val) => setState(() {
                  _termsAccepted = val ?? false;
                  if (_termsAccepted && _generalError == 'You must accept the Terms of Service.') {
                    _generalError = null;
                  }
                }),
                activeColor: Theme.of(context).colorScheme.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() {
                  _termsAccepted = !_termsAccepted;
                  if (_termsAccepted && _generalError == 'You must accept the Terms of Service.') {
                    _generalError = null;
                  }
                }),
                child: Text(
                  'I agree to the Terms of Service',
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : const Color(0xFF6B7280),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),

        if (_generalError != null) ...[
          const SizedBox(height: 16),
          _buildErrorBanner(_generalError!, isDark),
        ],

        if (_registerStatus != null) ...[
          const SizedBox(height: 12),
          _buildStatusBanner(_registerStatus!, isDark),
        ],

        const SizedBox(height: 24),
        AuthButton(
          label: 'Create Account',
          isLoading: _isRegistering,
          onPressed: () => _handleRegister(),
        ),
        const SizedBox(height: 20),

        Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Already have an account? ',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white54 : const Color(0xFF6B7280),
                ),
              ),
              TextButton(
                onPressed: () => context.go('/login'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'Sign In',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ],
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

  Widget _buildStatusBanner(String message, bool isDark) {
    final primary = isDark ? GibberTheme.eclipsePurple : GibberTheme.arcticBlue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: primary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}