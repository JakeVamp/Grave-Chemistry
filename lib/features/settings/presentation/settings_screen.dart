import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/loading_button.dart';
import '../../../shared/widgets/placeholder_screen.dart';
import '../../auth/application/auth_providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _signingOut = false;

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    // The router returns the user to the sign-in screen once signed out.
    await ref.read(authControllerProvider.notifier).signOut();
    if (mounted) setState(() => _signingOut = false);
  }

  @override
  Widget build(BuildContext context) {
    return PlaceholderScreen(
      title: 'Settings',
      icon: Icons.settings_outlined,
      message: 'Settings are not built yet.',
      actions: [
        LoadingButton(
          label: 'Sign out',
          isLoading: _signingOut,
          onPressed: _signOut,
        ),
      ],
    );
  }
}
