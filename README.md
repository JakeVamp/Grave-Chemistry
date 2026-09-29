# Grave Chemistry

A dating app built with Flutter and Supabase for iOS and Android.

> **Status:** Foundation, email/password authentication, first-time profile
> setup and live photo verification (manual review) are in place, plus
> server-side anti-abuse foundations. The other screens are still
> placeholders. Features get built one step at a time.

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

4. **Configure Supabase Auth**: see [Supabase Auth setup](#supabase-auth-setup)
   below. Email links will not open the app until this is done.

5. **Apply the database migrations**: see
   [Database migrations](#database-migrations). Profile setup can't save
   until the `profiles` table exists.

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

## Database migrations

Schema changes live in `supabase/migrations/` as timestamped SQL files, in
the format the Supabase CLI expects. Apply them in filename order. Never edit
a migration that has already been applied; add a new one instead.

**Option A: SQL Editor (simplest).** In the Supabase dashboard, open
**SQL Editor → New query**, paste the full contents of the migration file,
and click **Run**. The whole script runs in one transaction, so it either
applies completely or not at all.

**Option B: Supabase CLI.** Run `supabase link --project-ref <your-ref>`
(it asks for your database password locally; never commit it), then
`supabase db push`. The CLI records which migrations have been applied.

Use one method per project. Mixing them can make the CLI try to re-run a
migration that was already applied in the SQL Editor.

Current migrations, in order:

1. `20260928120000_create_profiles.sql`: profiles and lookup tables
2. `20260929100000_security_foundation.sql`: `private` schema, rate
   limits, account status, abuse flags, moderator checks
3. `20260929100100_live_photo_verification.sql`: verification sessions,
   audit log, private storage bucket and policies
4. `20260929100200_anti_abuse.sql`: devices, phones, deletion records,
   sign-up hook
5. `20260929120000_trust_and_safety.sql`: abuse signals, content scanning,
   trust levels, Discovery eligibility, reports, blocks, message-abuse
   primitives, media/duplicate-image foundation, moderation audit
6. `20260929120100_child_safety.sql`: child-safety cases, account holds,
   media quarantine, reviewer-only evidence access, evidence bucket
7. `20260930100000_profile_photos.sql`: public profile photos, private
   `profile-photos` bucket, visibility-gated storage policies, photo RPCs

After applying them, check **Project Settings → Data API → Exposed
schemas** and make sure `private` is **not** listed.

### Testing migrations locally

`tool/test_database.sh` applies every migration to a throwaway local
PostgreSQL (with a small stand-in for Supabase's `auth` and `storage`
schemas) and runs the security tests in `supabase/tests/`. It needs the
PostgreSQL server binaries (`initdb`, `pg_ctl`, `psql`).

## How profiles work

- **Table.** `public.profiles` has one row per auth user (`id` =
  `auth.users.id`). Email and password stay in Supabase Auth.
- **Extensible choices.** Community identities, dating preferences and
  gender options are rows in lookup tables (`community_identities`,
  `dating_preferences`, `gender_options`). To add a value, insert a row;
  to retire one, set `is_active = false`. The app's enums
  (`CommunityIdentity`, `DatingPreference`, `GenderOption`) must list the
  same codes.
- **Completion is decided by the database.** A trigger computes
  `profile_completed` on every insert and update, and clients have no
  permission to write that column. The app validates with the same rules
  first, only for fast feedback.
- **Age.** Users must be 18 or older, calculated from `birth_date` in UTC.
  Age is never stored. `birth_date` is private to its owner; future
  discovery features must expose only a computed age.
- **Access (RLS).** Signed-in users can create, read and update only their
  own profile. Anonymous users have no access. There is no delete policy;
  profiles are removed with the auth user.
- **Routing.** After sign-in the app loads the profile. Users without a
  completed profile are kept on `/profile-setup`; users with one go to the
  app.

## Live photo verification

Onboarding ends with a live photo taken with the camera (never the photo
library). It is uploaded to a private bucket and reviewed. Submitting moves
the user to `pending`, not `verified`; only a moderator or, later, a trusted
liveness provider can approve. See
[docs/security/verification-and-anti-abuse.md](docs/security/verification-and-anti-abuse.md)
for the full design, trust boundaries, retention and what production
automation still needs.

## Public profile photos

Users add up to 6 photos from their library (Home → Profile photos). Each
is stripped of metadata, uploaded to the private `profile-photos` bucket and
reviewed before anyone else can see it; approved photos are only served
through signed URLs to eligible viewers. Verification photos are a separate
system and can never become profile photos. See
[docs/security/profile-photos.md](docs/security/profile-photos.md).

## Trust, safety and child safety

Server-side foundations for Discovery and messaging: eligibility checks,
reports, blocks, spam/scam/commercial-solicitation signals, moderation audit
and a separate child-safety pipeline. See
[docs/security/trust-and-safety.md](docs/security/trust-and-safety.md) and
[docs/security/child-safety.md](docs/security/child-safety.md).

## Common commands

```sh
dart format lib test            # format
flutter analyze                 # static analysis
flutter test                    # unit + widget tests
tool/test_database.sh           # SQL migration + security tests
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
│   ├── profile/                  # domain/ data/ application/ presentation/
│   ├── profile_photos/           # domain/ data/ application/ presentation/
│   ├── verification/             # domain/ data/ application/ presentation/
│   └── settings/presentation/
└── shared/                       # Reusable, feature-agnostic code
    ├── utils/
    └── widgets/
test/                             # Mirrors lib/
env/
└── example.json                  # Template for local env files (committed)
supabase/
├── migrations/                   # Versioned SQL, applied in filename order
└── tests/                        # SQL security tests (tool/test_database.sh)
docs/security/                    # Security design documents
tool/                             # Developer scripts
```

### Conventions

- **Feature-first folders.** Each feature owns its code under
  `lib/features/<feature>/`. When a feature grows, add `domain/` (models,
  interfaces, pure logic), `data/` (Supabase implementations) and
  `application/` (Riverpod providers, state) next to `presentation/`.
  `features/auth/` is the reference example.
- **Features never import from other features**, except for account-level
  state: any feature may use `features/auth/application/` (auth state,
  sign-out) and `features/profile/application/` or `profile/domain/` (the
  signed-in user's profile and onboarding state). Other shared code goes in
  `lib/shared/` or `lib/core/`.
- **No database queries in widgets.** Widgets call a controller in
  `application/`, which uses a repository interface from `domain/`,
  implemented in `data/`.
- **Route paths live in `AppRoutes`.** Don't write path strings in widgets.
- **Get Supabase from `supabaseClientProvider`**, not `Supabase.instance`,
  so tests can override it.
- **Colours and spacing come from `AppColors` / `AppSpacing`** or the theme.
  Don't hardcode them in widgets.

## Visual direction

A dark gothic placeholder theme: near-black and charcoal backgrounds, deep
burgundy accents, and light readable text. There is no final artwork or
branding yet.
