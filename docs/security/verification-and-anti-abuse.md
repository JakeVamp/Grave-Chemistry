# Live photo verification and anti-abuse design

This document explains how verification and duplicate-account prevention
work, where the trust boundaries are, and what is still required before the
system is production-grade. Code lives in:

- `supabase/migrations/20260929100000_security_foundation.sql`
- `supabase/migrations/20260929100100_live_photo_verification.sql`
- `supabase/migrations/20260929100200_anti_abuse.sql`
- `lib/features/verification/`
- Tests: `supabase/tests/*_test.sql` (run `tool/test_database.sh`) and
  `test/features/verification/`

## Trust boundaries

| Actor | Can | Cannot |
|---|---|---|
| Flutter app (user JWT) | Start a session, upload one photo into its own open session, submit it, read its own profile status | Choose the challenge, mark anything passed, set any verification/account status, read sessions, audit logs, devices, flags or other users' media |
| Moderator (JWT with `app_metadata.role = moderator` **and** `aal = aal2`) | Approve/reject submitted sessions, require reverification, change account status (not their own) | Review their own verification or change their own status |
| Trusted backend (service role, e.g. Edge Functions) | Post liveness-provider results, run retention jobs, link verified phones | — |
| Database | Enforces every rule above | — |

`app_metadata` can only be written with the service role (Admin API), so
users cannot grant themselves roles. There is no admin flag on profiles.

All private data lives in the `private` schema, which must **not** be added
to the Data API's exposed schemas. API roles have no privileges on its
tables; they reach it only through `SECURITY DEFINER` functions in `public`
that validate the caller.

## Verification flow

1. User finishes their profile. The router sends them to `/verification`.
2. They read why a live photo is required and tap **Start verification**.
3. The app requests **camera permission only now**.
4. The app calls `start_verification_session()`. The server:
   - checks the profile is complete and not already pending/verified,
   - enforces rate limits and the repeated-rejection lock,
   - supersedes any older open session,
   - **chooses a random challenge** (look straight, turn left/right, blink,
     smile) and a short expiry (10 minutes by default),
   - writes `verification_requested`/`retry_requested` and
     `challenge_issued` audit events.
5. The front camera opens directly (the `camera` plugin, audio disabled).
   There is no gallery or file picker anywhere in the flow.
6. The user captures a photo, sees it, and can retake. The camera is closed
   during review. The photo exists only in memory; the plugin's temporary
   file is deleted immediately.
7. Before upload the app re-encodes the JPEG: orientation applied, **all
   EXIF removed** (GPS, device model, timestamps), resized to 1600px max.
8. Upload goes to the private `verification-media` bucket at
   `<session uuid>/<32 random hex>.jpg`. No user ID, email or name in the
   path. Storage policies only allow this into the caller's own **open,
   unexpired** session.
9. The app calls `submit_verification_session(session_id, path)`. The
   server re-checks ownership, expiry, reuse and that the object exists and
   belongs to the caller, then sets the session to `submitted` and the
   profile to **`pending`**. Uploading never produces `verified`.
10. The router moves the user to `/verification/pending`, a limited state.

### Status model

Profile `verification_status` (public, server-controlled):

```
not_started ─┐
rejected ────┼─ submit ─▶ pending ─ approve ─▶ verified ─ revoke ─▶ reverification_required
expired ─────┤                     └ reject ──▶ rejected   └ expire ─▶ expired
reverification_required ┘
```

Transitions are enforced by `private.set_verification_status()`; anything
else raises `invalid_verification_transition`.

`profiles.verified_badge` is a generated column (`status = 'verified'`). It
is the only verification fact future discovery views should expose. The app
shows a badge only for `verified` (`VerificationStatus.showsVerifiedBadge`).

Session status (private): `issued → submitted → approved | rejected`, or
`issued → expired | superseded`. A session is single-use: once submitted it
can't be submitted or uploaded to again.

### Routing

| Onboarding state | Route |
|---|---|
| Profile incomplete | `/profile-setup` |
| Profile complete, not started | `/verification` |
| Pending | `/verification/pending` |
| Rejected, expired, reverification required | `/verification/retry` |
| Verified | the app |

The guard is loop-free by construction and tested exhaustively
(`test/core/router/auth_guard_test.dart`).

## Liveness challenges

The server picks the challenge; the app only displays the instruction. The
client can never mark a challenge as passed. Today a human reviewer checks
the photo against the instruction. The `challenge_type`, `liveness_result`,
`provider_reference` and `verification_method` columns exist so a provider
can take over without schema changes.

No home-grown computer vision is used, and no facial embeddings, templates
or similarity scores are stored.

## Device / app integrity (not implemented; integration points ready)

Do not fake attestation. When adding it:

1. **Client:** after `start_verification_session()`, obtain an attestation
   bound to the session ID (use it as the nonce/challenge):
   - iOS: **App Attest** (`DCAppAttestService`), falling back to
     **DeviceCheck** where App Attest is unavailable.
   - Android: **Play Integrity API** standard request with the session ID
     hashed into `requestHash`.
2. **Backend:** an Edge Function `attest-verification-session` verifies the
   token with Apple/Google, checks the nonce matches the session and the app
   ID is `com.gravechemistry.app`, then (service role) sets
   `attestation_status`, `attestation_provider` and `attested_at` on the
   session.
3. **Enforcement:** set `private.security_settings.attestation_required =
   true`. `submit_verification_session()` then returns
   `attestation_required` for any session without a valid attestation.

## Rate limits (server-side)

Rules live in `private.rate_limit_rules`, events in
`private.rate_limit_events`; `private.try_consume_rate_limit()` serialises
per action/subject so concurrent requests can't slip past.

| Action | Default | Subject |
|---|---|---|
| `verification_session_start_hourly` | 5 / hour | user |
| `verification_session_start_daily` | 10 / day | user |
| `verification_submit` | 10 / hour | user |
| Repeated rejections | 3 in 30 days locks new sessions and raises a review flag | user |
| `signup_per_ip` | 10 / hour | HMAC of IP (throttle only) |
| `phone_verification_attempt` | 5 / hour | user |
| `device_registration` | 30 / day | user |

Also enable Supabase Auth's built-in rate limits and CAPTCHA (Cloudflare
Turnstile is free) for sign-up and sign-in. Schedule
`private.purge_rate_limit_events()` daily with Supabase Cron (pg_cron).

## Audit log

`private.verification_audit_log` records `verification_requested`,
`challenge_issued`, `photo_submitted`, `submission_failed`, `approved`,
`rejected`, `retry_requested`, `session_expired`, `verification_revoked` and
`media_deleted`, with `actor_type` (user/system/moderator) and `actor_id`
for privileged actions.

It is append-only: a trigger rejects updates and deletes (a deliberate
purge must set `app.allow_audit_purge`). It has no foreign keys, so history
survives account deletion. `details` holds reason codes only, never image
data, paths, URLs or tokens. Users can't read it.

## Media security and retention

- Private bucket, JPEG only, 5 MB limit, no public URLs.
- Only object paths are stored, never URLs.
- Reviewers get access through a backend that issues **short-lived signed
  URLs** (e.g. 60 seconds) after checking the moderator claim. Never log the
  signed URL.
- Retention (configurable in `private.security_settings`, starting from the
  outcome):

| Outcome | Default |
|---|---|
| Approved | 30 days |
| Rejected | 30 days |
| Abandoned (expired/superseded) | 1 day |
| Account deleted | queued immediately in `private.media_deletion_queue` |

**Cleanup job (to build):** a scheduled Edge Function (service role) that
calls `private.verification_media_due_for_deletion()`, deletes each object
through the **Storage API** (not by deleting `storage.objects` rows), then
calls `private.mark_verification_media_deleted()`; and drains
`private.media_deletion_queue`. Also schedule
`private.expire_verification_sessions()`.

Submitted-but-unreviewed media has no deadline; reviews must keep up, or add
a maximum pending age.

## Anti-abuse

- **Email:** Supabase Auth stays the only source of login identities; email
  is never copied into public tables.
- **Devices:** `register_device(install_id, platform)` accepts only an
  app-generated random UUID (hashed with a server-side key). No IMEI,
  serials, MAC addresses or advertising IDs. Each account gets its own row;
  one account can never claim another's. More than 2 accounts on one install
  within 90 days raises a `shared_install` flag. *The app does not call this
  yet*; it needs a persisted install UUID and a call after sign-in.
- **Phones:** `private.phone_identities` allows one active account per
  hashed phone number (unique index) and one active phone per account.
  `private.link_verified_phone()` is for a trusted backend after code
  verification. Phone verification itself (SMS) is not implemented and
  usually needs a paid SMS provider, which requires approval.
- **Deletion:** a trigger on `auth.users` writes a tombstone with only
  hashed email, phones and install IDs, releases phones and queues media for
  deletion. The same email can't sign up again for 7 days (365 days if the
  account was restricted/suspended or had confirmed flags). The same phone
  can't be relinked during that time. Recreated accounts are flagged.
- **Sign-up hook:** `public.hook_before_user_created` enforces the
  recreation cooldown and throttles sign-ups per hashed IP. Enable it under
  Authentication → Hooks → Before User Created (Postgres function).
- **Account status:** `private.accounts.status` is `pending_verification`
  until approval, then `active`; `restricted`, `suspended` and
  `deletion_pending` are set by moderators only. The app does not act on
  these statuses yet.
- **Flags:** `private.abuse_signals` (generalised in the trust & safety migration) holds signals for human
  review. No signal, and certainly not a shared IP, suspends an account
  automatically.

Retention of tombstones and flags needs legal/privacy review; a sensible
default is to purge tombstones after their cooldown plus a short buffer.

## Admin security

- Grant roles only through the Admin API (`app_metadata.role`).
- **Moderator/admin accounts must use MFA before production.** The database
  already requires `aal2` for moderator actions; enable TOTP MFA in Supabase
  Auth and enrol every moderator.
- Build the review tool as a separate, access-controlled surface (not the
  consumer app), calling `review_verification_session()` with the
  moderator's own session.

## Biometric data and legal review

This implementation stores a photo for manual review only. It stores no
facial geometry, embeddings, templates or similarity scores.

Before adding automated face matching or liveness scoring, get legal review
covering at least:

- US biometric laws: Illinois BIPA (written notice, written consent, public
  retention/destruction schedule, private right of action), Texas CUBI,
  Washington's biometric law, and newer state laws.
- GDPR/UK GDPR Article 9 (biometric data for identification is special
  category: explicit consent, DPIA required), and CCPA/CPRA sensitive
  personal information.
- A vendor data processing agreement: where processing happens, whether the
  vendor keeps templates, retention, sub-processors.
- App Store privacy labels and Google Play Data safety disclosures.
- Updated privacy policy and in-app consent screen.

Prefer a provider that returns a pass/fail result without Grave Chemistry
retaining biometric templates.

## What automated, production-grade verification still needs

1. An approved liveness/identity provider (usually paid; needs approval).
2. The provider's mobile SDK in the capture step (active or passive
   liveness), replacing the plain camera capture.
3. An Edge Function that creates provider sessions bound to our session ID
   and receives signed webhooks, calling
   `apply_verification_provider_result()` with the service role.
4. Device attestation (above), then `attestation_required = true`.
5. The media cleanup job and session-expiry schedule.
6. A moderator review tool with MFA, signed URLs and audit visibility, for
   manual review and appeals.
7. Legal/privacy review and consent UI (above).
8. Monitoring and alerts on flag volume, rejection rates and rate-limit hits.
