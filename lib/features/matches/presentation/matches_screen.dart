import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class MatchesScreen extends StatelessWidget {
  const MatchesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Matches',
      icon: Icons.favorite_border,
      message: 'Matches are not built yet.',
    );
  }
}
