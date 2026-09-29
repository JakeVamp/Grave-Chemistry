# Trust & safety foundation

Anti-fake-profile, anti-spam, scam-prevention and commercial-solicitation
groundwork, built before Discovery and messaging. Child safety is separate:
see [child-safety.md](child-safety.md).

Code: `supabase/migrations/20260929120000_trust_and_safety.sql`.
Tests: `supabase/tests/trust_and_safety_test.sql` (`tool/test_database.sh`).

Grave Chemistry is a dating/community app, not a marketplace for paid
content. The system discourages and detects content sellers, scams, spam,
fake profiles and account farms. Signals **feed review and eligibility**;
nothing bans or suspends automatically, and no single weak signal (such as a
shared IP address) changes anything.

## What exists now vs. what is foundation

| Area | Works now | Foundation for later |
|---|---|---|
| Discovery eligibility | Server computes it; user can query a coarse result | Discovery queries must filter with `private.can_interact()` |
| Content scanning | Bio and display name scanned on every change | Social handles, prompts, photo captions call `private.scan_user_text()` |
| Reports | `submit_report`, `my_submitted_reports` RPCs | Report buttons in the app |
| Blocks | `block_user`, `unblock_user`, `my_blocked_users` RPCs | Block buttons; Discovery/matching/messaging must use `can_interact()` |
| Trust & risk | Computed from server state | Ranking or throttling by trust level |
| Message abuse | `private.check_outbound_message()` primitive | The messaging backend must call it for every send |
| Rate limits | Rules and `private.consume_user_action()` | Likes/conversations/messages must call it |
| Duplicate images | Tables, hash matching, reuse signals | Upload pipeline must compute and register hashes |
| Moderation | `moderate_user`, `review_abuse_signal`, audit log | A moderator tool (not built) |

## Discovery eligibility

`private.is_discovery_eligible(user)` is true only when **all** hold:

- email confirmed (`auth.users.email_confirmed_at`)
- profile complete (server-computed)
- 18 or older (re-checked from the birth date, not only at save time)
- `verification_status = 'verified'`
- account status `active`
- trust level is not `review_required`, `restricted` or `suspended`
- no active child-safety hold

There is no client-writable "eligible" flag anywhere. The app can call
`public.get_my_discovery_eligibility()`, which returns `eligible` plus coarse
reasons only (`email_unconfirmed`, `profile_incomplete`,
`verification_required`, `account_unavailable`), never review, risk or safety
details.

`private.can_interact(actor, target)` = both eligible, not the same person,
and no block in either direction. **Every future Discovery query, like, match
and message must go through it.**

## Trust levels and risk

`private.trust_level(user)` is computed on demand, never stored, so it can't
be forged or go stale:

| Level | When |
|---|---|
| `suspended` | account suspended, banned or pending deletion |
| `restricted` | account restricted, or an active child-safety hold |
| `review_required` | a moderator flag, or internal risk score ≥ threshold (default 12) |
| `new` | not verified yet |
| `established` | verified, account older than 30 days, no open weighted signals, no major profile change in 14 days |
| `verified` | otherwise |

The internal risk score sums open signals from the last 90 days: signal-type
weight × severity (low 1, medium 2, high 4). Weights live in
`private.abuse_signal_types`; `shared_ip` has weight 0 (context only). The
score is never exposed to users.

## Abuse signals

`private.abuse_signals` (formerly `duplicate_account_flags`) records signal
type, category, source, severity, review status and timestamps. Categories:
duplicate account, fake profile, commercial solicitation, spam, scam,
profile change and user report. Repeats of the same open signal within a day
are collapsed (severity upgraded). Only moderators change review status.

## Content scanning and commercial solicitation

`private.content_rules` holds case-insensitive patterns, each producing a
signal type and severity:

| Rule | Signal | Examples it catches |
|---|---|---|
| `url`, `many_urls` | external_link, repeated_external_links | links; 3+ links |
| `payment_handle` | payment_handle | Cash App, Venmo, PayPal, `$handle`, crypto |
| `paid_content` | paid_content_solicitation | OnlyFans, Fansly, "selling my pics", "custom content" |
| `money_request` | money_request | "send me money", gift cards, "sugar daddy" |
| `subscription` | subscription_promotion | "subscribe to", promo codes, "20% off" |
| `price_list` | price_list_pattern | "$20 per pic", "50 dollars a video" |
| `off_platform` | off_platform_redirect | Telegram, WhatsApp, "add me on" |
| `commercial_sexual` | commercial_sexual_content | "nudes for sale", "sexting service" |
| `promo_language` | promotional_language | "link in bio", "DM for prices" |

A trigger scans `display_name` and `bio` on every change. Only the rule code
and field name are stored, never the text. Several commercial signals
together push an account to `review_required`, which removes eligibility
until a moderator looks. Keywords alone never restrict or suspend.

Rules are data: tune or add patterns with an `insert`/`update`, no migration
needed. Expect false positives (e.g. someone mentioning Bitcoin); that's why
signals go to review.

## Profile change re-checks

For verified users, changes to display name, birth date, gender or community
identity, and large bio changes, are recorded in
`private.profile_change_events` and raise low/medium signals. Changing a
birth date after verification sets `manual_review_required`. `established`
trust is lost for 14 days after any major change, and every change is
re-scanned, so a trusted account can't be quietly swapped for scam content.
Future photo changes should insert a `photo` change event (the duplicate-image
path already does).

## Reports

`public.submit_report(user, category, details)` supports `fake_profile`,
`impersonation`, `stolen_photos`, `selling_content`,
`scam_or_money_request`, `spam`, `underage_concern`, `harassment`,
`hate_or_threats` and `other` (plus the child-safety categories).

- Stored in `private.user_reports`; the reported user can never read it.
- The reporter's identity is never exposed to the reported user.
  `my_submitted_reports()` shows reporters only their own reports.
- Contents are immutable after submission (trigger), even for admins; only
  review fields change, via moderator functions.
- Reporting an unknown account or repeating an open report reveals nothing.
- Each non-child-safety report adds a `user_report` signal whose severity
  grows with the number of distinct reporters.
- Rate limited (20/day).

## Blocks

`private.blocks` with `block_user`, `unblock_user` and `my_blocked_users`
(only blocks you made). Nobody can list who blocked them, and blocking an
unknown ID is a silent no-op (no account probing). `is_blocked_between()` is
symmetric and is part of `can_interact()`.

## Message-abuse primitives (messaging not built)

`private.check_outbound_message(sender, recipient, body, is_first_message)`
is for the future messaging backend. It refuses pairs that can't interact
and enforces new-account first-message and link limits. It stores a **keyed
hash of the normalised text**, not the text, for 7 days to detect the same
message sent to many people, flags commercial or off-platform pushes in
first messages, and scans the text. Content signals don't block delivery;
accumulated signals send the sender to review, which then blocks further
messages.

Privacy: no message content is stored for abuse detection. Hashes are keyed
(not reversible by dictionary attack without the server key) and purged by
`private.purge_message_fingerprints()`, which should be scheduled daily. If
messaging later needs content retention (e.g. for reports), document the
retention period in the privacy policy.

## Rate limits for new accounts

Rules in `private.rate_limit_rules`; `private.consume_user_action(user,
action)` automatically applies the stricter `<action>_new_account` rule
during the first 7 days:

| Action | Normal | New account |
|---|---|---|
| like | 200/day | 50/day |
| conversation_create | 50/day | 10/day |
| first_message | 100/day | 20/day |
| external_link_message | 20/day | 3/day |
| report_submit | 20/day | — |
| block_user | 100/day | — |

Account recreation is limited by the tombstone cooldown and the sign-up
hook from the anti-abuse migration.

## Duplicate public images (non-biometric)

`private.media_assets` holds future profile photos and message attachments.
When photos are built, the trusted upload backend (an Edge Function with the
service role) should:

1. Receive the upload into a private bucket with `moderation_state =
   'pending_scan'`.
2. Compute a SHA-256 (exact copies) and a 64-bit perceptual hash such as
   dHash or pHash (near copies: resized, recompressed, lightly edited). These
   describe the image's pixels, not a face.
3. Call `private.register_media_hashes(asset, sha256, phash)`. Matches
   against other accounts' public photos (Hamming distance ≤ 6 by default)
   raise `reused_public_image` signals that link the other account.
4. Run child-safety provider checks (see child-safety.md), then approve.
5. Serve photos only through `public.resolve_public_media()`, which returns
   an object path (never a URL) only for approved, non-quarantined media of
   a visible owner, to an eligible viewer who isn't blocked.

No facial recognition, face embeddings or biometric templates are computed
or stored. Row identity (owner, path, hashes) is immutable once set.

## Moderation audit

`public.moderate_user(user, action, reason, report_id)` supports `dismiss`,
`warn`, `restrict`, `suspend`, `ban`, `require_reverification`,
`lift_restriction` and `clear_review`. Every action is written to
`private.moderation_actions` (append-only). Moderators need the
`moderator`/`admin` role in `app_metadata` (Admin API only) **and** MFA
(`aal2`), and can't act on themselves. Users can't read or change any
moderation record.

## Phone verification (architecture only)

Unchanged: one verified phone per active account, enforced by a unique index
on hashed numbers (`private.phone_identities`), with deletion cooldowns.

Sending codes needs an SMS/verification provider, which is paid per
verification. Options:

- **Supabase Auth phone OTP** with an SMS provider it supports (Twilio,
  MessageBird, Vonage, Textlocal); simplest if phone becomes a login factor.
- **A Verify API** (Twilio Verify, Vonage Verify) called from an Edge
  Function, if phone is only an anti-abuse check.

On successful verification the backend (service role) calls
`private.link_verified_phone(user, e164)`; a small service-role-only public
wrapper will be added then. **Choosing a provider needs your approval
because of cost.**

## Manual steps / scheduling

- Schedule with Supabase Cron: `private.purge_message_fingerprints()` and
  `private.purge_rate_limit_events()` daily.
- Tune `private.security_settings` (thresholds, periods) and
  `private.content_rules` as real data arrives.
