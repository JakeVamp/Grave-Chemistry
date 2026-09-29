# Public profile photos

Code: `supabase/migrations/20260930100000_profile_photos.sql`,
`lib/features/profile_photos/`.
Tests: `supabase/tests/profile_photos_test.sql`,
`test/features/profile_photos/`.

## Separation from verification

| | Verification photo | Public profile photo |
|---|---|---|
| Source | Live front camera only | Photo library (system picker) |
| Bucket | `verification-media` | `profile-photos` |
| Records | `private.verification_sessions` | `private.media_assets` + `private.profile_photos` |
| Who sees it | Reviewers only | Eligible people, after approval |

The two never mix. Verification photos can't be read back by their owner
(the read policy was removed), so they also can't be copied into a
profile-photo slot with Storage's copy operation. A profile-photo slot only
accepts an object at the exact path the server reserved.

## Lifecycle

1. **Reserve:** `begin_profile_photo_upload()` checks the account isn't held
   or restricted, enforces the limit (6 active photos including pending
   uploads) and the daily rate limit, then creates a media asset in
   `awaiting_upload` with a server-chosen path
   `<asset uuid>/<32 random hex>.jpg`.
2. **Upload:** the app strips EXIF/GPS metadata, re-encodes to JPEG and
   uploads to that path. The bucket is private, JPEG-only, 5 MB max, and the
   insert policy only allows the owner's reserved, unexpired (30 min) slot.
3. **Complete:** `complete_profile_photo_upload()` confirms the file exists,
   moves the asset to `pending_scan` and adds it to the user's photos (first
   photo becomes primary).
4. **Pipeline:** a trusted backend worker validates, strips metadata,
   fingerprints and scans the photo; the database decides approval,
   rejection, quarantine or manual review. See
   [photo-pipeline.md](photo-pipeline.md). Moderators (role + MFA) can also
   approve (only after successful processing), reject or remove.
5. **Serve:** approved photos are listed by `get_profile_photos(user)` and
   read through signed URLs.

## Visibility

A photo is shown to another user only when **all** hold:

- moderation state is `approved` (not pending, rejected, quarantined,
  removed)
- the photo isn't removed
- the owner is Discovery-eligible: email confirmed, profile complete, 18+,
  verified, account active, not under review, no child-safety hold
- the viewer is Discovery-eligible
- no block in either direction

The same rule (`private.can_view_profile_photo`) drives both the RPC and the
Storage select policy, so direct Storage API calls can't bypass it; Storage
only issues signed URLs for objects the caller may read. Owners can always
view their own non-quarantined photos.

## Ownership and editing

All operations are RPCs; users have no table access. Users can reorder
(`reorder_profile_photos`, must list exactly their current photos), choose
the primary (`set_primary_profile_photo`) and delete
(`delete_profile_photo`: soft removal, file queued for deletion). Photos
under child-safety review, or any photo while the account has a safety hold,
can't be deleted, so evidence is preserved.

Invariants enforced by the database: ownership and creation time are
immutable, removal is one-way, at most one primary (unique index) and
exactly one primary whenever photos exist (deferred constraint trigger).
Stable order by `position`.

Users see only a coarse status: `in_review`, `live` or `not_approved`.
Quarantine shows as `in_review` with no file path; moderation reasons,
fingerprints and child-safety details are never returned.

## Profile change review

Every new photo needs approval, whatever the account's trust level. For
verified users each new photo is a `photo` profile change, which resets
"established" trust for 14 days, and 3+ new photos within 7 days raise a
`photo_replacement` review signal. A reviewer tool should compare new photos
against the verification photo by eye; no facial recognition is used.

## Child safety

A provider match (`report_child_safety_media_match`, service role) or a
moderator/reviewer flag (`flag_media_for_child_safety`) quarantines the
photo, holds the account and opens a case with legal hold for CSAM
categories. Quarantined photos are unservable, hidden from the owner, can't
be deleted, approved or released outside child-safety review, and evidence
is only reachable through the reviewer-only audited function.

## Manual steps

- Apply the migration (after the previous six).
- Confirm the `profile-photos` bucket is private with the 5 MB / JPEG limits.
- If policy creation fails with "must be owner of table objects", create the
  two policies from the migration in Storage → Policies.
- Deploy and schedule the processing and clean-up functions
  (see [photo-pipeline.md](photo-pipeline.md)).
