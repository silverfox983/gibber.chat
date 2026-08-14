import 'package:flutter/material.dart';

class AuthTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData prefixIcon;
  final bool obscureText;
  final bool isPassword;
  final String? errorText;
  final bool isLoading;
  final bool showSuccess;
  final String? domainSuffix;
  final TextInputType? keyboardType;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTogglePassword;
  final VoidCallback? onSubmitted;
  final FocusNode? focusNode;

  const AuthTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.prefixIcon,
    this.obscureText = false,
    this.isPassword = false,
    this.errorText,
    this.isLoading = false,
    this.showSuccess = false,
    this.domainSuffix,
    this.keyboardType,
    this.hint,
    this.onChanged,
    this.onTogglePassword,
    this.onSubmitted,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasError = errorText != null && errorText!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white70 : const Color(0xFF4B5563),
          ),
        ),
        const SizedBox(height: 6),
        _buildField(context, isDark, hasError),
        if (hasError) ...[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildField(BuildContext context, bool isDark, bool hasError) {
    final cs = Theme.of(context).colorScheme;
    final surfaceContainerHighest = isDark
        ? const Color(0xFF1E293B)
        : const Color(0xFFF3F4F6);
    final fillColor = hasError
        ? cs.error.withValues(alpha: 0.08)
        : surfaceContainerHighest;
    final borderColor = hasError
        ? cs.error.withValues(alpha: 0.5)
        : isDark
            ? Colors.white24
            : const Color(0xFFE5E7EB);
    final focusedBorderColor = hasError ? cs.error : cs.primary;
    final textColor = isDark ? Colors.white : const Color(0xFF111827);
    final hintColor = isDark ? Colors.white54 : const Color(0xFF9CA3AF);

    Widget? suffixIcon;
    if (isPassword && onTogglePassword != null) {
      suffixIcon = IconButton(
        icon: Icon(
          obscureText ? Icons.visibility_off_rounded : Icons.visibility_rounded,
          color: hintColor,
          size: 20,
        ),
        onPressed: onTogglePassword,
        splashRadius: 16,
      );
    } else if (isLoading) {
      suffixIcon = Padding(
        padding: const EdgeInsets.all(14),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: isDark ? Colors.white54 : cs.primary,
          ),
        ),
      );
    } else if (showSuccess) {
      suffixIcon = Padding(
        padding: const EdgeInsets.all(14),
        child: Icon(Icons.check_circle_rounded, color: Colors.green.shade400, size: 20),
      );
    }

    InputDecoration decoration = InputDecoration(
      prefixIcon: Icon(prefixIcon, color: hintColor, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: fillColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: borderColor, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: focusedBorderColor, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      hintText: hint,
      hintStyle: TextStyle(color: hintColor, fontWeight: FontWeight.w400),
    );

    if (domainSuffix != null && suffixIcon == null) {
      decoration = decoration.copyWith(
        suffixIcon: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text(
            domainSuffix!,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: hintColor),
          ),
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
      );
    }

    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      keyboardType: keyboardType,
      style: TextStyle(color: textColor, fontWeight: FontWeight.w500, fontSize: 15),
      decoration: decoration,
      onChanged: onChanged,
      onSubmitted: onSubmitted != null ? (_) => onSubmitted!() : null,
    );
  }
}