# Grave Chemistry

A dating app built with Flutter and Supabase for iOS and Android.

> **Status:** Foundation and email/password authentication are in place.
> The other screens are still placeholders. Features get built one step at
> a time.

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

4. **Configure Supabase Auth** — see [Supabase Auth setup](#supabase-auth-setup)
   below. Email links will not open the app until this is done.

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

## Supabase Auth setup

These settings live in the Supabase dashboard and can't be set from the app.

1. **Enable email sign-in with confirmation.**
   Authentication → Sign In / Providers → Email: enable the provider and turn
   on **Confirm email**.
2. **Match the password rule.** In the same Email settings, set
   **Minimum password length** to `8`, the same minimum the app enforces
   (`AuthValidators.minPasswordLength`).
3. **Allow the app's redirect URL.** Authentication → URL Configuration →
   **Redirect URLs**: add

   ```
   com.gravechemistry.app://login-callback
   ```

   If this is missing, Supabase sends users to the **Site URL** instead and
   the app never receives the link.
4. **Email templates.** Leave the default *Confirm signup* and
   *Reset password* templates using `{{ .ConfirmationURL }}`. You can edit
   the wording, but keep that link.
5. **Email delivery.** Supabase's built-in email sender is for testing only.
   It is heavily rate-limited and only delivers to members of your Supabase
   organisation. Before real users sign up, configure custom SMTP under
   Project Settings → Authentication → SMTP. That usually means a
   third-party email provider, which may have a cost.

### How auth works in the app

- **State.** `authControllerProvider` holds `SignedOut`, `SignedIn` or
  `PasswordRecovery`, driven by Supabase's auth events.
- **Routing.** `authGuard` (`lib/core/router/auth_guard.dart`) redirects
  signed-out users to `/auth` and signed-in users away from auth screens.
  During password recovery it keeps the user on `/reset-password` until a new
  password is set. Every redirect target is allowed for the same state, so
  redirects can't loop. A unit test checks this for every route.
- **Email links.** Confirmation and reset emails link back to
  `com.gravechemistry.app://login-callback`, which is registered in
  `AndroidManifest.xml` and `Info.plist`. `supabase_flutter` exchanges the
  link for a session using PKCE, so links must be opened on the device that
  requested them. Flutter's built-in deep-link routing is turned off so these
  links never reach the router.
- **Sessions** are persisted and refreshed automatically by
  `supabase_flutter`, so users stay signed in across restarts.

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
│   ├── router/                   # go_router setup, route paths, auth guard
│   ├── supabase/                 # Supabase init, client provider, auth callback URL
│   └── theme/                    # Colours, spacing, ThemeData
├── features/                     # One folder per feature
│   ├── auth/                     # domain/ data/ application/ presentation/
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
  `lib/features/<feature>/`. When a feature grows, add `domain/` (models,
  interfaces, pure logic), `data/` (Supabase implementations) and
  `application/` (Riverpod providers, state) next to `presentation/`.
  `features/auth/` is the reference example.
- **Features never import from other features**, with one exception:
  any feature may use `features/auth/application/` for auth state and
  actions (e.g. sign-out). Other shared code goes in `lib/shared/` or
  `lib/core/`.
- **Route paths live in `AppRoutes`.** Don't write path strings in widgets.
- **Get Supabase from `supabaseClientProvider`**, not `Supabase.instance`,
  so tests can override it.
- **Colours and spacing come from `AppColors` / `AppSpacing`** or the theme.
  Don't hardcode them in widgets.

## Visual direction

A dark gothic placeholder theme: near-black and charcoal backgrounds, deep
burgundy accents, and light readable text. There is no final artwork or
branding yet.
