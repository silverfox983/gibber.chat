import 'package:flutter/material.dart';

class AuthButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isDisabled;
  final bool isSecondary;
  final IconData? icon;

  const AuthButton({
    super.key,
    required this.label,
    this.onPressed,
    this.isLoading = false,
    this.isDisabled = false,
    this.isSecondary = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    final Color backgroundColor;
    final Color foregroundColor;
    final Color disabledColor;

    if (isSecondary) {
      backgroundColor = isDark
          ? const Color(0xFF1E293B)
          : const Color(0xFFF3F4F6);
      foregroundColor = isDark ? Colors.white : const Color(0xFF111827);
      disabledColor = isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB);
    } else {
      backgroundColor = cs.primary;
      foregroundColor = Colors.white;
      disabledColor = cs.primary.withValues(alpha: 0.5);
    }

    final effectiveOnPressed = (isLoading || isDisabled) ? null : onPressed;

    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: effectiveOnPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: (isLoading || isDisabled) ? disabledColor : backgroundColor,
          foregroundColor: foregroundColor,
          disabledBackgroundColor: disabledColor,
          disabledForegroundColor: foregroundColor.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: isSecondary ? 0 : 2,
          shadowColor: isSecondary ? Colors.transparent : backgroundColor.withValues(alpha: 0.3),
        ),
        child: isLoading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: foregroundColor,
                ),
              )
            : icon != null
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                          color: foregroundColor,
                        ),
                      ),
                    ],
                  )
                : Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                      color: foregroundColor,
                    ),
                  ),
      ),
    );
  }
}