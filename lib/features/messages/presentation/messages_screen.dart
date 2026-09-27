import 'package:flutter/material.dart';

import '../../../shared/widgets/placeholder_screen.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: 'Messages',
      icon: Icons.chat_bubble_outline,
      message: 'Messaging is not built yet.',
    );
  }
}
