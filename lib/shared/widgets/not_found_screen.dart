import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_routes.dart';
import 'placeholder_screen.dart';

class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key, required this.location});

  final Uri location;

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: 'Page not found',
      icon: Icons.help_outline,
      message: 'Nothing lives at "${location.path}".',
      actions: [
        FilledButton(
          onPressed: () => context.go(AppRoutes.home),
          child: const Text('Back to home'),
        ),
      ],
    );
  }
}
