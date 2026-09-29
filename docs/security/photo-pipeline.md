# Profile photo processing pipeline

Code:
- Database: `supabase/migrations/20260930120000_photo_processing_pipeline.sql`
- Edge Functions: `supabase/functions/process-profile-photos/`,
  `supabase/functions/cleanup-media/`, shared code in
  `supabase/functions/_shared/`
- Tests: `supabase/tests/photo_pipeline_test.sql` (`tool/test_database.sh`),
  `supabase/functions/tests/` (`tool/test_functions.sh`)

## Principle

The worker (Edge Function) only **reports facts**: file validity, sizes,
fingerprints and provider results. Every decision (approve, reject,
quarantine, manual review, retry) is made by
`public.pipeline_submit_result()` in the database. The worker and
database functions run with the service role; the Flutter app can call
none of them and can never approve a photo.

## States

`media_assets.moderation_state` remains the source of truth for visibility.
`private.photo_processing.stage` tracks pipeline progress.
`private.photo_pipeline_state()` combines them:

| State | Meaning | Owner sees |
|---|---|---|
| pending_upload | slot reserved, file not confirmed | — |
| uploaded | waiting for the worker | In review |
| processing | leased by a worker (5 min lease) | In review |
| awaiting_provider | an async provider job is pending | In review |
| awaiting_manual_review | a human must decide | In review |
| processing_failed | failed; retried with backoff | In review |
| approved | visible to eligible viewers | Live |
| rejected | never visible | Not approved |
| quarantined | child-safety hold | In review (no file) |
| removed | deleted by owner or moderator | (gone) |

Owners only ever get `in_review`, `live` or `not_approved`. No reasons,
provider names, hashes, risk data or child-safety details.

## Flow

1. Upload completes → `photo_processing` row in `uploaded` (trigger), event
   `upload_accepted`.
2. **Claim:** `pipeline_claim_photos()` leases photos that are due. A photo
   is only handed out if it's still `pending_scan`, not removed, belongs to
   its uploader, has a matching object at the reserved path in
   `profile-photos`, has no child-safety case, and its owner has no safety
   hold. `FOR UPDATE SKIP LOCKED` lets several workers run safely.
3. **Process (Edge Function):**
   1. check bucket and path shape (`<photo id>/<32 hex>.jpg`)
   2. download; validate: non-empty, ≤ 5 MB, JPEG signature, valid marker
      structure ending in EOI, dimensions 200–4096 px (checked before
      decoding), decodable
   3. normalise: apply EXIF orientation, re-encode (quality 90) without any
      metadata, overwrite the stored object
   4. SHA-256 and 64-bit perceptual hash of the normalised image
   5. child-safety provider (image + SHA-256 only, no user data)
   6. moderation provider, **skipped** when child safety reports a match
      (suspected material is never sent to another provider)
4. **Submit:** `pipeline_submit_result(photo, attempt, result)`:
   - Results for anything but the current attempt are ignored ("stale"),
     so retries and duplicate deliveries are idempotent.
   - Validation is cross-checked with Storage's own object metadata (size,
     MIME type); a client-declared type is never trusted. Invalid → rejected.
   - Fingerprints are recorded once (`register_media_hashes`); exact or
     near duplicates of another account's photo create
     `reused_public_image` signals and force manual review. Retries reuse
     the recorded result and never duplicate signals.
   - Child safety: `possible_match` / `confirmed_known_hash_match` →
     child-safety case (once per photo), quarantine, account hold, legal
     hold, never approved. `manual_review_required` or no result → manual
     review. `provider_error` → retry. `pending` → awaiting_provider.
   - Moderation: `reject` → rejected (low review signal);
     `manual_review` / no result → manual review; `provider_error` → retry.
   - Unknown provider values are treated as missing (fail closed).
   - Otherwise → approved.
5. **Failures** (`pipeline_report_failure`, or provider errors): never
   approve; retry after 2, 4, 8, 16 minutes; after 5 attempts the photo
   stops and appears in the moderator queue; `moderator_retry_photo_processing`
   restarts it.

## Perceptual hash (near duplicates)

**Algorithm:** 64-bit difference hash (dHash). The normalised image is
reduced to 9×8 greyscale cells by area averaging; each bit records whether a
cell is brighter than its right-hand neighbour. It describes the image's
brightness structure, not a person. No face detection, embeddings or
biometric templates.

**Threshold:** Hamming distance ≤ 6 of 64 bits
(`private.security_settings.near_duplicate_image_distance`), compared against
other accounts' approved and pending profile photos.

**Detects well (tested):** resized copies, recompressed copies (down to
quality 30), light crops (~2% per edge).

**Limitations:** mirrored or rotated copies, heavier crops, collages,
overlays or strong filters won't match. Very plain images (solid colours,
simple gradients) can collide.

**False positives:** a match never bans or rejects. The photo goes to
manual review and the account gets a review signal; a moderator dismisses
it if the match is wrong.

## Providers

`_shared/providers.ts` defines `ChildSafetyProvider` (results: clear,
possible_match, confirmed_known_hash_match, provider_error,
manual_review_required, pending) and `ModerationProvider` (approve, reject,
manual_review, provider_error, pending, plus internal categories such as
explicit_sexual, graphic_violence, promotional, text_solicitation,
not_a_person).

**No provider is configured.** The defaults return "manual review", so every
photo waits for a moderator: nothing is auto-approved without an approved
provider. Selecting an unknown provider name makes the function refuse to
run.

To add a provider (after approval): implement the interface in a new file
(e.g. `_shared/providers/photodna.ts`), select it in `providersFromEnv`
via `CHILD_SAFETY_PROVIDER=photodna`, and read its credentials from Edge
Function secrets. Candidates for child safety: Microsoft PhotoDNA, Thorn
Safer. Nothing contacts NCMEC or law enforcement; legal reporting stays a
separate human process (docs/security/child-safety.md).

Tests use fake providers only (`supabase/functions/tests/fake_providers.ts`)
and synthetic images generated in memory.

## Secrets

| Secret | Where |
|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | provided automatically to Edge Functions |
| `PHOTO_PIPELINE_CRON_SECRET` (≥ 32 random chars) | Edge Function secret **and** Supabase Vault (for the Cron job) |
| Future provider keys (e.g. `PHOTODNA_SUBSCRIPTION_KEY`) | Edge Function secrets only |

Never in the repo, the Flutter app or database tables. Set Edge Function
secrets with `supabase secrets set NAME=value` or Dashboard → Edge
Functions → Secrets.

## Deployment (manual)

```sh
supabase functions deploy process-profile-photos --no-verify-jwt
supabase functions deploy cleanup-media --no-verify-jwt
supabase secrets set PHOTO_PIPELINE_CRON_SECRET='<long random value>'
```

`--no-verify-jwt` is needed because Cron calls without a user JWT. The
functions instead require the `x-cron-secret` header and refuse all
requests if the secret isn't set.

## Cron jobs (manual)

Enable the `pg_cron` and `pg_net` extensions (Dashboard → Database →
Extensions), store the same secret in Vault, then schedule both functions.
Replace `<project-ref>`.

```sql
select vault.create_secret('<same long random value>', 'photo_pipeline_cron_secret');

select cron.schedule(
  'process-profile-photos',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/process-profile-photos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                        where name = 'photo_pipeline_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);

select cron.schedule(
  'cleanup-media',
  '17 * * * *',
  $$
  select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/cleanup-media',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                        where name = 'photo_pipeline_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $$
);
```

## Storage clean-up

`media_deletion_queue` now tracks status, attempts and errors.
`cleanup_enqueue_expired()` queues rejected photos 30 days after the decision
(`decided_at`), abandoned upload slots, and verification media past retention.
`cleanup_claim_deletions()` never hands out anything under quarantine, an
open or legal-hold child-safety case, a safety hold, or in the evidence
bucket; those are marked `skipped_hold`. The worker re-checks with
`cleanup_confirm_deletable()` immediately before deleting through the
Storage API, then records the result; repeats are no-ops.

## Moderator support

With the moderator role and MFA:

- `moderator_photos_awaiting_review()`: manual-review and failed photos
  (never child-safety cases)
- `moderate_profile_photo(photo, approve|reject|remove)`: approval requires
  successful validation, no child-safety result or case, no account hold
- `moderator_retry_photo_processing(photo)`
- `moderator_photo_review_context(photo)`: storage locations of the photo
  and the owner's latest approved verification photo, for side-by-side
  review by eye through short-lived signed URLs. Audited; refused for
  anything under child-safety review
- `flag_media_for_child_safety(photo, category)`: quarantine and escalate
- `moderate_user(user, 'require_reverification', …)`

Child-safety evidence still needs the `child_safety_reviewer` role.

## Before production

- Choose and contract a child-safety provider (and optionally a
  moderation provider); implement the adapter. Until then every photo
  needs a moderator.
- Deploy both functions, set secrets, create the Cron jobs.
- Build the moderator tool (signed URLs from a backend that re-checks the
  role).
- Load-test the worker; tune batch size and schedule.
- Legal review of child-safety reporting (unchanged requirement).
