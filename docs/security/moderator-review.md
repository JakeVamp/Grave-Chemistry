# Moderator photo review

Code:
- Database: `supabase/migrations/20261001100000_moderator_photo_review.sql`
- Edge Function: `supabase/functions/moderator-review-media/` (logic in
  `supabase/functions/_shared/review_media.ts`)
- App: `lib/features/moderation/`
- Tests: `supabase/tests/moderator_review_test.sql`,
  `supabase/functions/tests/review_media_test.ts`,
  `test/features/moderation/`

## Access

| Check | Where |
|---|---|
| `app_metadata.role` is `moderator` (or `admin`) | database, every call (`private.is_moderator()`) |
| Session is MFA-verified (`aal2`) | database, every call |
| Moderator navigation shown | app only (cosmetic; never relied on) |

`app_metadata` can only be set with the service role, so users can't grant
themselves the role. A role placed in `user_metadata` is ignored. The
`child_safety_reviewer` role is separate and gets no moderator access.

The app's Moderator tools screen asks for a 6-digit authenticator code (or
sets up an authenticator first) when the session isn't `aal2` yet. Supabase
Auth must have TOTP MFA enabled (it is by default).

## Moderator accounts and member onboarding

Moderator tools are a separate staff path. A signed-in account whose
`app_metadata.role` is `moderator` can reach Moderator Home without a member
profile or live-photo verification: while member onboarding is unfinished,
the app sends it to Moderator Home instead of the dating app, and the MFA
step still applies. This is navigation only and changes nothing on the
server:

- the database still requires the moderator role and MFA for every
  moderator request (no profile is needed for them, and none is created)
- `verification_status` is untouched; the account is not verified
- Discovery eligibility is unchanged: an unfinished moderator account is
  not eligible, has no visible photos and can't reach the dating app
- child-safety holds and account checks apply as before

A moderator can still choose "Set up member profile" and go through normal
onboarding. Roles in `user_metadata` are ignored.

## Flow

Home → Moderator tools (MFA) → Photo review (queue) → Review photo.

1. **Queue:** `moderator_photo_review_queue()` returns photos waiting for
   manual review or whose processing failed, oldest first, with: name, age,
   verification status, whether the account has open review signals,
   duplicate match (`exact` / `similar`), automated moderation flag,
   whether automated checks were incomplete, and whether it can be approved
   or retried. No storage paths, hashes, provider data, reason codes or
   child-safety data. Photos load only when a moderator opens an item.
2. **Review:** the app calls the `moderator-review-media` Edge Function with
   the moderator's own session. The function calls
   `moderator_photo_review_context(photo)` **as the moderator**, so the
   database re-checks role + MFA, refuses anything under child-safety
   review, and audits the access. Only then does it sign two URLs with the
   service role, valid for **60 seconds**, and only for the
   `profile-photos` and `verification-media` buckets. The app downloads
   both immediately, discards the URLs, and shows the photos side by side
   from memory.
3. **Decide:** approve, reject, remove, retry processing, require
   re-verification, or escalate to child safety. After a final action the
   item leaves the queue and the next photo opens; an empty queue says
   "All caught up".

This is a comparison **by eye**. There is no facial recognition, face
embedding, biometric matching or automated identity scoring.

## Photo privacy in the app

- No save, download or share controls, and no gestures on the photos.
- Android: screenshots and screen recording are blocked (`FLAG_SECURE`)
  while the review screen is open. iOS has no supported API for this.
- Photos are held in memory only; the decoded images are evicted from
  Flutter's image cache when the screen closes. Nothing is written to disk.
- Signed URLs are never stored, logged or shown.

## Actions and safety conditions

| Action | Function | Confirmation | Final |
|---|---|---|---|
| Approve | `moderate_profile_photo(photo, 'approve')` | no (database enforces every gate) | yes |
| Reject | `moderate_profile_photo(photo, 'reject')` | yes | yes |
| Remove | `moderate_profile_photo(photo, 'remove')` | yes | yes |
| Retry processing | `moderator_retry_photo_processing(photo)` | no | yes |
| Require re-verification | `moderate_user(owner, 'require_reverification', reason)` | yes | no |
| Escalate to child safety | `flag_media_for_child_safety(photo, category)` | yes, with category | yes |

Approval still requires: successful validation, no child-safety result or
case, no account hold, and (new) that the photo is **waiting for manual
review**. So a photo whose processing failed, one being processed again, or
one another moderator already decided can't be approved. Reject is refused
for an already rejected photo.

When the database refuses, the app shows a generic message (database text
is never shown), refreshes the item and the queue, and never retries or
works around the refusal.

## Child-safety separation

A photo is hidden from ordinary moderators (queue, item, notes, review
context, retry) when it is quarantined, has a child-safety case, or its
owner has an active safety hold. This now also applies to
`moderator_photos_awaiting_review()`, which previously still listed photos
of held accounts. Escalating a photo quarantines it, holds the account and
opens one case (a second escalation doesn't open another). The escalating
moderator can't open it again. Evidence stays reachable only through
`child_safety_access_evidence()` (child-safety reviewer + MFA).

## Moderator notes

`private.moderator_notes`: append-only (no edits or deletes), with photo,
member, moderator id and time. Written through `moderator_add_photo_note()`
(1–1000 characters) and read through `moderator_photo_notes()`, both
moderator-only. Not returned by any member-facing function. The app tells
moderators not to put links or child-safety details in notes.

## Audit trail

Every moderator photo action writes a row to `private.moderation_actions`
(append-only) with moderator id, action, member, photo and time:

| Action code | When |
|---|---|
| `photo_review_opened` | review context fetched (i.e. photos shown) |
| `photo_approve` / `photo_reject` / `photo_remove` | decisions |
| `photo_retry` | processing restarted |
| `require_reverification` | account must verify again |
| `photo_escalate_child_safety` | escalated |
| `photo_note_added` | note added |

The photo's own history (`private.photo_processing_events`) also records
comparison access, approval, rejection, removal and retries. No image
bytes, URLs or storage paths are logged.

## Failure handling

| Situation | Behaviour |
|---|---|
| Signed URL can't be created | Edge Function returns an error; no URLs at all |
| Signed URL expired / download fails / not a JPEG / too large | no photos shown; "Reload photos" requests new URLs |
| Verification photo fails to load | profile photo shown; verification panel says it couldn't be loaded |
| Processing failed | approve disabled; retry offered |
| Already reviewed by another moderator | action refused; banner explains; item leaves the queue |
| Escalated or account held meanwhile | item becomes unavailable; photos closed |
| MFA lost or role removed | refused; Moderator tools asks for verification again |
| Database refuses an action | generic message; item and queue refreshed |

## Manual steps

1. Apply `20261001100000_moderator_photo_review.sql` (after the previous
   eight migrations).
2. Deploy the function **with** JWT verification (the default):
   `supabase functions deploy moderator-review-media`. It uses only the
   secrets Supabase provides (`SUPABASE_URL`, `SUPABASE_ANON_KEY`,
   `SUPABASE_SERVICE_ROLE_KEY`).
3. Give moderators the role with the Admin API or SQL, e.g.
   `update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role":"moderator"}' where id = '<user id>';`
   They must sign in again for the role to reach their session.
4. Confirm TOTP MFA is enabled under Authentication → Multi-Factor.

## Limitations

- iOS can't block screenshots.
- The queue shows at most 50 items per refresh.
