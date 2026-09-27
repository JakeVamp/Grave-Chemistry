import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class DiscoveryScreen extends StatelessWidget {
  const DiscoveryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Discovery',
      icon: Icons.explore_outlined,
      message: 'Discovery is not built yet.',
    );
  }
}
