# Child-safety foundation

Grave Chemistry is strictly 18+. This foundation detects, flags, quarantines
and escalates suspected child sexual abuse material (CSAM) and serious
underage-safety concerns. It is deliberately separate from ordinary spam,
scam, adult-content and general moderation.

Code: `supabase/migrations/20260929120100_child_safety.sql`.
Tests: `supabase/tests/child_safety_test.sql`.

> **We do not build our own CSAM classifier.** Detection comes from trusted
> industry providers and from user reports. The database never decides that
> content *is* CSAM and never contacts external organisations.

## Three separated stages

| Stage | Who | What the system does |
|---|---|---|
| 1. Automated detection | Trusted provider (hash matching / classification) or a user report | Opens a case, quarantines media, holds the account |
| 2. Internal review | Authorised child-safety reviewers only (role + MFA) | Views evidence through audited access, updates the case |
| 3. Legal / reporting decision | Legal/trust & safety lead, per legal advice | Makes any external report outside the system; records only a reference |

No stage triggers the next one automatically across these boundaries.

## Protected categories (internal only)

`suspected_csam`, `known_csam_hash_match`,
`sexual_content_involving_possible_minor`, `underage_user_concern`,
`adult_soliciting_minor`, `grooming_concern`. They live only in
`private.child_safety_cases` and are never visible to users or ordinary
moderators.

User report reasons: `underage_concern`, `suspected_csam`,
`adult_soliciting_minor`, `grooming_concern`. All are `critical` priority,
above every normal report. Reporter identity is never revealed.

## What happens on a signal

`private.open_child_safety_case()`:

1. Creates a case (`critical` for CSAM and solicitation, else `high`). CSAM
   categories get `legal_hold = true` (preservation).
2. **Quarantines** linked media: `moderation_state = 'quarantined'` plus a
   `private.media_quarantine` record. Quarantined media is never returned by
   `resolve_public_media()` or any user API.
3. **Holds the account** (`private.account_safety_holds`). A hold makes the
   account `restricted` for trust purposes, removes Discovery eligibility and
   blocks all interaction via `can_interact()`. This is enforced in the
   database, not the app, and overrides an otherwise complete, verified
   profile.
4. Writes immutable events to `private.child_safety_events`.

Hold policy for user reports: CSAM and adult-soliciting-minor reports hold
immediately. Underage and grooming concerns hold once a second, independent
person reports the same account within 30 days (a single malicious report
can't silently remove someone; repeated concerns act quickly). Provider and
moderator cases always hold. Tune in `private.route_child_safety_report()`.

## Protections

- **Quarantine can't be lifted by users or ordinary moderators.** A trigger
  blocks leaving quarantine unless called from the reviewer release function,
  even for direct admin SQL.
- **Media identity is immutable.** Owner, path and hashes can't change, so
  the uploader can't swap the object or metadata to dodge review.
- **Holds and quarantine records** can't be deleted, and are released only
  through `public.child_safety_release()` after a reviewer closes the case
  as `closed_no_violation`.
- **Media under legal hold is never released** back to users.
- **Evidence access:** `public.child_safety_access_evidence(case)` returns the
  storage location only to `child_safety_reviewer` accounts with MFA, and
  logs every call. Ordinary moderators are refused. Reviewers too work only
  through these audited functions; they can't read the tables directly.
- **Events and reason codes only:** no image bytes, paths, URLs, hashes or
  report text in events or logs.
- **Evidence bucket:** `child-safety-evidence` is private with **no storage
  policies**, so only the service role can touch it. Quarantined objects
  should be moved there through the Storage API; reviewers get very
  short-lived signed URLs from a reviewer-gated backend, never permanent
  URLs.

## Age safety

- The profiles trigger rejects any birth date under 18 for everyone,
  including admins; the client can't bypass it.
- Discovery eligibility re-checks age from the birth date.
- Credible underage concerns hold the account under
  `underage_user_concern` until a reviewer decides.

## Provider integration points (to build)

Candidate services (eligibility and terms vary; confirm before choosing):

- **Microsoft PhotoDNA Cloud Service** (hash matching against known CSAM;
  free for qualifying organisations)
- **Thorn Safer** (hash matching plus classifier; commercial)
- **Google Content Safety API** (classifier for prioritising review; free for
  eligible partners)
- **Cloudflare CSAM Scanning Tool** (if media is served through Cloudflare)

Where they plug in:

1. **Profile photo upload:** upload lands in a private bucket as
   `pending_scan` → the upload Edge Function sends the image (or its hash, per
   provider) to the provider **before** approval → on a match it calls
   `public.report_child_safety_media_match(asset, match_type, provider_ref)`
   with the service role → the case, quarantine and hold happen at once.
   Only clean results continue to duplicate-image checks and approval.
2. **Future message attachments:** same pipeline, run before the attachment
   is delivered to the recipient.
3. **Moderation review:** reviewers open cases in a dedicated, access-
   controlled tool (not built) that calls the `child_safety_*` functions and
   requests signed URLs from a backend that re-checks the reviewer role.

Never store real CSAM or real hash lists in the repository or test
environments. Automated tests use synthetic placeholders only (see
`child_safety_test.sql`).

## Escalation workflow (outline for legal review)

1. **Intake:** a case is opened automatically (provider/report), with the
   account held and media quarantined and preserved.
2. **Triage (target: hours, not days):** a child-safety reviewer confirms
   whether the content or conduct is apparent CSAM or child endangerment.
   Minimise viewing; use provider metadata and blurred previews where
   possible.
3. **Escalate:** `child_safety_update_case(case, 'escalated_legal')`.
4. **Legal/reporting decision:** a designated lead, following counsel's
   procedure, makes any required report (for US providers, typically to
   NCMEC's CyberTipline) **outside this system**, then records the reference
   with `child_safety_record_external_report()`.
5. **Preserve:** keep evidence and relevant account data for the legally
   required period; don't delete media under legal hold.
6. **Enforce:** ban through `moderate_user` where appropriate.
7. **Close:** `closed_actioned` or `closed_no_violation` (only the latter
   allows releasing a hold).

Development and test environments must never send reports to law
enforcement or external organisations.

## Required before production

- **Legal review** of reporting and preservation obligations in every launch
  market. For example, US providers have reporting duties under 18 U.S.C.
  § 2258A and preservation requirements; the UK Online Safety Act and EU
  rules impose their own duties. Confirm specifics with counsel.
- A signed agreement with at least one child-safety provider, integrated in
  the upload pipeline.
- The evidence-move and signed-URL backend, and the reviewer tool.
- Named, trained child-safety reviewers with MFA, access reviews and
  wellbeing support.
- Retention schedule for cases, events and preserved evidence.
- Incident runbook and on-call ownership for critical cases.
