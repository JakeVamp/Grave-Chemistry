import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class ProfileSetupScreen extends StatelessWidget {
  const ProfileSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Profile setup',
      icon: Icons.person_outline,
      message: 'Profile setup is not built yet.',
    );
  }
}
