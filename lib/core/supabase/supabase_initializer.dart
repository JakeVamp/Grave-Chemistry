import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';

abstract final class SupabaseInitializer {
  static Future<void> initialize(AppConfig config) async {
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabasePublishableKey,
    );
  }
}
