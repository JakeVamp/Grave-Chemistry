import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Settings',
      icon: Icons.settings_outlined,
      message: 'Settings are not built yet.',
    );
  }
}
