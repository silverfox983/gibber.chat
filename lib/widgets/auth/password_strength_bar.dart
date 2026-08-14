import 'package:flutter/material.dart';

class PasswordStrengthBar extends StatelessWidget {
  final String password;

  const PasswordStrengthBar({super.key, required this.password});

  PasswordStrength get strength {
    if (password.isEmpty) return PasswordStrength.none;
    int score = 0;
    if (password.length >= 8) score++;
    if (password.length >= 12) score++;
    if (RegExp(r'[A-Z]').hasMatch(password)) score++;
    if (RegExp(r'[a-z]').hasMatch(password)) score++;
    if (RegExp(r'[0-9]').hasMatch(password)) score++;
    if (RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(password)) score++;

    if (score <= 2) return PasswordStrength.weak;
    if (score <= 3) return PasswordStrength.fair;
    if (score <= 4) return PasswordStrength.good;
    return PasswordStrength.strong;
  }

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) return const SizedBox.shrink();

    final s = strength;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final Color color;
    final String label;
    final int filledSegments;

    switch (s) {
      case PasswordStrength.weak:
        color = const Color(0xFFEF4444);
        label = 'Weak';
        filledSegments = 1;
      case PasswordStrength.fair:
        color = const Color(0xFFF59E0B);
        label = 'Fair';
        filledSegments = 2;
      case PasswordStrength.good:
        color = const Color(0xFF10B981);
        label = 'Good';
        filledSegments = 3;
      case PasswordStrength.strong:
        color = const Color(0xFF06B6D4);
        label = 'Strong';
        filledSegments = 4;
      case PasswordStrength.none:
        return const SizedBox.shrink();
    }

    final inactiveColor = isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Row(
          children: List.generate(4, (i) {
            return Expanded(
              child: Container(
                height: 4,
                margin: EdgeInsets.only(right: i < 3 ? 4 : 0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: i < filledSegments ? color : inactiveColor,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

enum PasswordStrength { none, weak, fair, good, strong }