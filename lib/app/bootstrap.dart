import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/config/app_config_provider.dart';
import '../core/supabase/supabase_initializer.dart';
import '../shared/utils/app_logger.dart';
import 'app.dart';
import 'configuration_error_app.dart';

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = AppConfig.fromEnvironment();
  final errors = config.validate();
  if (errors.isNotEmpty) {
    AppLogger.error('Invalid app configuration: ${errors.join(' ')}');
    runApp(ConfigurationErrorApp(errors: errors));
    return;
  }

  await SupabaseInitializer.initialize(config);
  AppLogger.info('Started in ${config.environment.name} environment.');

  runApp(
    ProviderScope(
      overrides: [appConfigProvider.overrideWithValue(config)],
      child: const GraveChemistryApp(),
    ),
  );
}
