import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Sign in',
      icon: Icons.lock_outline,
      message: 'Authentication is not built yet.',
    );
  }
}
