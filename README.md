# Grave Chemistry

A dating app built with Flutter and Supabase for iOS and Android.

> **Status:** Project foundation only. The screens are placeholders.
> Features get built one step at a time.

## Tech stack

| Concern          | Choice                                   |
| ---------------- | ---------------------------------------- |
| UI framework     | Flutter (Dart)                           |
| Backend          | Supabase (`supabase_flutter`)            |
| Routing          | `go_router`                              |
| State / DI       | `flutter_riverpod`                       |
| Config / secrets | `--dart-define-from-file` (built into Flutter) |

## Prerequisites

- Flutter SDK (stable channel; see `environment.sdk` in `pubspec.yaml`)
- Xcode (for iOS) and/or Android Studio with an Android SDK (for Android)
- A Supabase project (the free tier is enough)

Run `flutter doctor` to confirm your toolchain works.

## Setup

1. **Install dependencies**

   ```sh
   flutter pub get
   ```

2. **Create your local environment file**

   ```sh
   cp env/example.json env/dev.json
   ```

   Fill in `env/dev.json` with values from your Supabase dashboard
   (**Project Settings → API**):

   | Key                        | Value                                                         |
   | -------------------------- | ------------------------------------------------------------- |
   | `APP_ENV`                  | `development`, `staging`, or `production`                     |
   | `SUPABASE_URL`             | Your project URL, e.g. `https://abcd1234.supabase.co`         |
   | `SUPABASE_PUBLISHABLE_KEY` | The **publishable** key (`sb_publishable_…`) or legacy **anon** key |

   `env/*.json` is git-ignored. Only `env/example.json` is committed.

3. **Run the app**

   ```sh
   flutter run --dart-define-from-file=env/dev.json
   ```

   If a value is missing or invalid, the app starts on a configuration-error
   screen that lists the problem. It will not crash.

### Security rules for configuration

- **Never** put the Supabase `service_role` or `sb_secret_…` key in the app or
  in any `env/*.json` file. Anything compiled into a mobile app can be
  extracted. The app refuses to start if it detects one of these keys.
- The publishable/anon key is safe to ship because access is controlled by
  Supabase Row Level Security (RLS). RLS policies must be in place before any
  real data is stored.
- Keep one file per environment (`env/dev.json`, `env/staging.json`,
  `env/prod.json`). Store production values in CI secrets, not on developer
  machines.

## Common commands

```sh
dart format lib test            # format
flutter analyze                 # static analysis
flutter test                    # unit + widget tests
flutter run --dart-define-from-file=env/dev.json

# Release builds
flutter build apk       --dart-define-from-file=env/prod.json
flutter build appbundle --dart-define-from-file=env/prod.json
flutter build ipa       --dart-define-from-file=env/prod.json
```

## Project structure

```
lib/
├── main.dart                     # Entry point; calls bootstrap()
├── app/
│   ├── app.dart                  # MaterialApp.router + theme
│   ├── bootstrap.dart            # Config validation, Supabase init, ProviderScope
│   └── configuration_error_app.dart
├── core/                         # App-wide infrastructure (no feature logic)
│   ├── config/                   # AppConfig, AppEnvironment, provider
│   ├── router/                   # go_router setup and route paths
│   ├── supabase/                 # Supabase initialisation and client provider
│   └── theme/                    # Colours, spacing, ThemeData
├── features/                     # One folder per feature
│   ├── auth/presentation/
│   ├── discovery/presentation/
│   ├── home/presentation/
│   ├── matches/presentation/
│   ├── messages/presentation/
│   ├── profile_setup/presentation/
│   └── settings/presentation/
└── shared/                       # Reusable, feature-agnostic code
    ├── utils/
    └── widgets/
test/                             # Mirrors lib/
env/
└── example.json                  # Template for local env files (committed)
```

### Conventions

- **Feature-first folders.** Each feature owns its code under
  `lib/features/<feature>/`. When a feature grows, add `data/` (Supabase
  queries, models) and `application/` (Riverpod providers, state) next to
  `presentation/`.
- **Features never import from other features.** Shared code goes in
  `lib/shared/` or `lib/core/`.
- **Route paths live in `AppRoutes`.** Don't write path strings in widgets.
- **Get Supabase from `supabaseClientProvider`**, not `Supabase.instance`,
  so tests can override it.
- **Colours and spacing come from `AppColors` / `AppSpacing`** or the theme.
  Don't hardcode them in widgets.

## Visual direction

A dark gothic placeholder theme: near-black and charcoal backgrounds, deep
burgundy accents, and light readable text. There is no final artwork or
branding yet.
