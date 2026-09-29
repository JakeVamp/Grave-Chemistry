-- Grave Chemistry: trust & safety foundation
--
-- Anti-fake-profile, anti-spam, scam-prevention and commercial-solicitation
-- groundwork, ahead of Discovery and messaging:
--   * generic abuse signals (the duplicate-account flags table is generalised)
--   * server-side content scanning for profile text
--   * trust levels and an internal risk score (never exposed)
--   * Discovery eligibility and pairwise interaction checks
--   * private reports and blocks
--   * reusable message-abuse primitives for future messaging
--   * media assets with a duplicate-image (perceptual hash) foundation
--   * profile change tracking so trust is never permanent
--   * new-account rate limits for future likes, conversations and messages
--   * an append-only moderation action log
--
-- Principles: signals feed human review and eligibility; nothing here bans
-- or suspends automatically; no text of profiles or messages is copied into
-- signal records; everything is server-controlled.

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

alter table private.security_settings
  add column new_account_period interval not null default interval '7 days',
  add column established_after interval not null default interval '30 days',
  add column profile_change_cooldown interval not null default interval '14 days',
  add column risk_window interval not null default interval '90 days',
  add column review_risk_threshold integer not null default 12,
  add column duplicate_message_recipients integer not null default 5,
  add column message_fingerprint_retention interval not null default interval '7 days',
  add column near_duplicate_image_distance integer not null default 6;

-- ---------------------------------------------------------------------------
-- Abuse signals (generalised from duplicate_account_flags)
-- ---------------------------------------------------------------------------

create table private.abuse_signal_types (
  code         text primary key check (code ~ '^[a-z][a-z0-9_]{0,59}$'),
  category     text not null check (category in (
    'duplicate_account', 'fake_profile', 'commercial_solicitation', 'spam',
    'scam', 'profile_change', 'user_report'
  )),
  -- Contribution to the internal risk score. 0 = recorded for context only.
  weight       integer not null check (weight between 0 and 10),
  description  text not null
);

insert into private.abuse_signal_types (code, category, weight, description) values
  -- existing duplicate-account signals
  ('shared_install',                'duplicate_account', 2, 'Several accounts on one app installation'),
  ('rapid_signup',                  'duplicate_account', 2, 'Many sign-ups in a short time'),
  ('repeated_verification_failure', 'duplicate_account', 3, 'Repeated rejected verifications'),
  ('account_recreation',            'duplicate_account', 2, 'Email or phone of a recently deleted account'),
  ('shared_phone',                  'duplicate_account', 4, 'Phone number already linked to another account'),
  ('provider_duplicate_identity',   'duplicate_account', 5, 'Verification provider reports a duplicate identity'),
  ('shared_ip',                     'duplicate_account', 0, 'Shared network address (context only, never counted)'),
  -- fake profiles / impersonation
  ('reused_public_image',           'fake_profile', 4, 'Public photo matches another account''s photo'),
  -- commercial solicitation
  ('paid_content_solicitation',     'commercial_solicitation', 4, 'Promotes paid content'),
  ('money_request',                 'commercial_solicitation', 3, 'Asks for money'),
  ('payment_handle',                'commercial_solicitation', 3, 'Payment handle or app'),
  ('subscription_promotion',        'commercial_solicitation', 3, 'Promotes a subscription'),
  ('commercial_sexual_content',     'commercial_solicitation', 5, 'Promotes commercial sexual content'),
  ('price_list_pattern',            'commercial_solicitation', 4, 'Price list for content or time'),
  ('external_link',                 'spam', 1, 'Contains an external link'),
  ('repeated_external_links',       'spam', 3, 'Repeated external links'),
  ('promotional_language',          'spam', 2, 'Promotional language'),
  ('duplicate_message_blast',       'spam', 4, 'Same message sent to many recipients'),
  ('first_message_velocity',        'spam', 3, 'Very high first-message volume'),
  -- scams
  ('off_platform_redirect',         'scam', 1, 'Pushes people to another platform'),
  ('immediate_commercial_solicitation', 'scam', 4, 'Commercial or off-platform push in a first message'),
  ('scam_behavior',                 'scam', 5, 'Scam behaviour confirmed by a moderator'),
  -- profile changes
  ('identity_change',               'profile_change', 2, 'Identity field changed after verification'),
  ('major_bio_change',              'profile_change', 1, 'Large bio change after verification'),
  -- reports (one per report; several reporters add up)
  ('user_report',                   'user_report', 2, 'Reported by another user');

alter table private.duplicate_account_flags rename to abuse_signals;
alter table private.abuse_signals
  drop constraint duplicate_account_flags_signal_type_check,
  add constraint abuse_signals_signal_type_fkey
    foreign key (signal_type) references private.abuse_signal_types (code),
  add column source text not null default 'system'
    check (source in (
      'system', 'content_scan', 'message_scan', 'media_scan', 'user_report',
      'verification', 'device', 'phone', 'rate_limit', 'moderator'
    ));

create index abuse_signals_open_user_idx
  on private.abuse_signals (user_id, created_at desc)
  where review_status = 'open';

-- Same arguments as before plus `p_source`. Repeats of an open signal within
-- a day are collapsed; a repeat with higher severity upgrades it.
drop function private.record_abuse_signal(uuid, text, text, jsonb, uuid);
create function private.record_abuse_signal(
  p_user_id uuid,
  p_signal_type text,
  p_severity text,
  p_details jsonb default '{}'::jsonb,
  p_related_user_id uuid default null,
  p_source text default 'system'
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  existing_id bigint;
begin
  select id into existing_id
  from private.abuse_signals
  where user_id = p_user_id
    and signal_type = p_signal_type
    and review_status = 'open'
    and created_at > now() - interval '1 day'
  order by created_at desc
  limit 1;

  if existing_id is not null then
    update private.abuse_signals
    set severity = case
      when p_severity = 'high' or severity = 'high' then 'high'
      when p_severity = 'medium' or severity = 'medium' then 'medium'
      else 'low' end
    where id = existing_id;
    return;
  end if;

  insert into private.abuse_signals
    (user_id, related_user_id, signal_type, severity, details, source)
  values (p_user_id, p_related_user_id, p_signal_type, p_severity,
          coalesce(p_details, '{}'::jsonb), p_source);
end;
$$;

-- Re-created against the renamed table (from the anti-abuse migration).
create or replace function private.record_account_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  account_status text;
  confirmed boolean;
begin
  select status into account_status from private.accounts where user_id = old.id;
  select exists (
    select 1 from private.abuse_signals
    where user_id = old.id and review_status = 'confirmed'
  ) into confirmed;

  insert into private.account_tombstones (
    deleted_user_id, email_hash, phone_hashes, install_id_hashes,
    prior_account_status, had_confirmed_flags, block_recreation_until
  )
  values (
    old.id,
    case when old.email is null then null else private.hash_identifier(old.email) end,
    coalesce((select array_agg(phone_hash) from private.phone_identities
              where user_id = old.id and status = 'active'), '{}'),
    coalesce((select array_agg(distinct install_id_hash) from private.devices
              where user_id = old.id), '{}'),
    account_status,
    confirmed,
    now() + case
      when confirmed or account_status in ('restricted', 'suspended', 'banned')
        then cfg.recreation_cooldown_after_enforcement
      else cfg.recreation_cooldown
    end
  );

  update private.phone_identities
  set status = 'released', released_at = now()
  where user_id = old.id and status = 'active';

  insert into private.media_deletion_queue (bucket_id, object_path)
  select 'verification-media', media_object_path
  from private.verification_sessions
  where user_id = old.id and media_object_path is not null and media_deleted_at is null;

  return old;
end;
$$;

-- ---------------------------------------------------------------------------
-- Account state additions
-- ---------------------------------------------------------------------------

alter table private.accounts
  drop constraint accounts_status_check,
  add constraint accounts_status_check check (status in (
    'active', 'pending_verification', 'restricted', 'suspended', 'banned', 'deletion_pending'
  )),
  -- Set by moderators or server rules; blocks Discovery until reviewed.
  add column manual_review_required boolean not null default false,
  add column review_reason text check (char_length(review_reason) <= 200);

-- Child-safety holds are defined in the child-safety migration, which
-- replaces this function. Until then no account has a hold.
create function private.has_active_safety_hold(p_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select false
$$;

-- ---------------------------------------------------------------------------
-- Content scanning
-- ---------------------------------------------------------------------------
-- Patterns produce signals for review, never enforcement on their own.
-- Only the rule code and field name are recorded, never the text.

create table private.content_rules (
  code         text primary key,
  signal_type  text not null references private.abuse_signal_types (code),
  pattern      text not null,
  severity     text not null check (severity in ('low', 'medium', 'high')),
  min_matches  integer not null default 1 check (min_matches >= 1),
  is_active    boolean not null default true
);

insert into private.content_rules (code, signal_type, pattern, severity, min_matches) values
  ('url', 'external_link',
   '(https?://|www\.)[^[:space:]]+|\y[a-z0-9-]+\.(com|net|org|io|me|co|ly|link|xyz|gg|tv|app|bio)\y',
   'low', 1),
  ('many_urls', 'repeated_external_links',
   '(https?://|www\.)[^[:space:]]+|\y[a-z0-9-]+\.(com|net|org|io|me|co|ly|link|xyz|gg|tv|app|bio)\y',
   'medium', 3),
  ('payment_handle', 'payment_handle',
   '\y(cash[[:space:]]?app|venmo|paypal|zelle|revolut|skrill|apple[[:space:]]?pay|google[[:space:]]?pay|bitcoin|ethereum|usdt|btc)\y|(^|[[:space:]])\$[a-z][a-z0-9_]{2,}',
   'medium', 1),
  ('paid_content', 'paid_content_solicitation',
   '\y(only[[:space:]]?fans|fansly|fanvue|manyvids|premium[[:space:]]+snap|selling[[:space:]]+(my[[:space:]]+)?(pics|content|nudes|videos)|custom[[:space:]]+(content|pics|videos)|content[[:space:]]+for[[:space:]]+sale|spicy[[:space:]]+link)\y',
   'high', 1),
  ('money_request', 'money_request',
   '\y(send[[:space:]]+(me[[:space:]]+)?money|need[[:space:]]+money|pay[[:space:]]+my[[:space:]]+(rent|bills)|gift[[:space:]]?cards?|sugar[[:space:]]?(daddy|baby)|allowance|financial[[:space:]]+help|help[[:space:]]+me[[:space:]]+pay)\y',
   'medium', 1),
  ('subscription', 'subscription_promotion',
   '\y(subscribe[[:space:]]+to|sub[[:space:]]+to[[:space:]]+my|subscription|promo[[:space:]]+code|discount[[:space:]]+code)\y|[0-9]{1,2}[[:space:]]?%[[:space:]]?off\y',
   'medium', 1),
  ('price_list', 'price_list_pattern',
   '(\$[[:space:]]?[0-9]+|[0-9]+[[:space:]]?(\$|usd|dollars))[[:space:]]*(/|per|for|a)?[[:space:]]*(pics?|photos?|videos?|vids?|mins?|minutes?|sessions?|hours?|hr)\y',
   'high', 1),
  ('off_platform', 'off_platform_redirect',
   '\y(telegram|whats[[:space:]]?app|kik|wickr|add[[:space:]]+me[[:space:]]+on|text[[:space:]]+me[[:space:]]+(on|at)|hit[[:space:]]+me[[:space:]]+up[[:space:]]+on|dm[[:space:]]+me[[:space:]]+on)\y|\ysnap(chat)?[[:space:]]*[:@]',
   'low', 1),
  ('commercial_sexual', 'commercial_sexual_content',
   '\y(nudes?[[:space:]]+for[[:space:]]+sale|sexting[[:space:]]+service|incall|outcall|pay[[:space:]]+to[[:space:]]+(see|watch))\y',
   'high', 1),
  ('promo_language', 'promotional_language',
   '\y(limited[[:space:]]+time|act[[:space:]]+now|click[[:space:]]+(the[[:space:]]+)?link|check[[:space:]]+out[[:space:]]+my[[:space:]]+(page|link|site)|link[[:space:]]+in[[:space:]]+(my[[:space:]]+)?bio|dm[[:space:]]+for[[:space:]]+(prices|menu|rates))\y',
   'medium', 1);

create function private.scan_text(p_text text)
returns table (rule_code text, signal_type text, severity text)
language sql
stable
set search_path = ''
as $$
  select r.code, r.signal_type, r.severity
  from private.content_rules r
  where r.is_active
    and p_text is not null
    and regexp_count(p_text, r.pattern, 1, 'i') >= r.min_matches
$$;

-- Scans a user-authored field and records signals. Reusable for future
-- social handles, prompts and message text.
create function private.scan_user_text(
  p_user_id uuid,
  p_field text,
  p_text text,
  p_source text default 'content_scan'
)
returns text[]
language plpgsql
set search_path = ''
as $$
declare
  hit record;
  found text[] := '{}';
begin
  for hit in select * from private.scan_text(p_text) loop
    perform private.record_abuse_signal(
      p_user_id, hit.signal_type, hit.severity,
      jsonb_build_object('field', p_field, 'rule', hit.rule_code), null, p_source);
    found := array_append(found, hit.signal_type);
  end loop;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------
-- Profile change tracking and re-checks
-- ---------------------------------------------------------------------------

create table private.profile_change_events (
  id           bigint generated always as identity primary key,
  user_id      uuid not null,
  change_kind  text not null check (change_kind in ('identity', 'bio_major', 'bio_minor', 'photo')),
  field        text not null,
  created_at   timestamptz not null default now()
);

create index profile_change_events_user_idx
  on private.profile_change_events (user_id, created_at desc);

-- Runs after every profile write. Scans changed text and, for verified
-- users, records identity and large bio changes so trust is re-earned
-- rather than permanent.
create function private.profiles_after_write_moderation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  was_verified constant boolean :=
    tg_op = 'UPDATE' and old.verification_status = 'verified';
  bio_hits text[] := '{}';
begin
  if tg_op = 'INSERT' or new.display_name is distinct from old.display_name then
    perform private.scan_user_text(new.id, 'display_name', new.display_name);
  end if;
  if tg_op = 'INSERT' or new.bio is distinct from old.bio then
    bio_hits := private.scan_user_text(new.id, 'bio', new.bio);
  end if;

  if not was_verified then
    return new;
  end if;

  if new.display_name is distinct from old.display_name
     or new.birth_date is distinct from old.birth_date
     or new.gender is distinct from old.gender
     or new.community_identity is distinct from old.community_identity then
    insert into private.profile_change_events (user_id, change_kind, field)
    values (new.id, 'identity', case
      when new.birth_date is distinct from old.birth_date then 'birth_date'
      when new.display_name is distinct from old.display_name then 'display_name'
      when new.gender is distinct from old.gender then 'gender'
      else 'community_identity' end);
    perform private.record_abuse_signal(new.id, 'identity_change', 'medium', '{}'::jsonb, null, 'system');
  end if;

  -- A verified person changing their birth date needs a human look.
  if new.birth_date is distinct from old.birth_date then
    update private.accounts
    set manual_review_required = true, review_reason = 'birth_date_changed_after_verification'
    where user_id = new.id;
  end if;

  if new.bio is distinct from old.bio then
    if old.bio is null
       or abs(char_length(coalesce(new.bio, '')) - char_length(old.bio)) > 150
       or cardinality(bio_hits) > 0 then
      insert into private.profile_change_events (user_id, change_kind, field)
      values (new.id, 'bio_major', 'bio');
      perform private.record_abuse_signal(new.id, 'major_bio_change', 'low', '{}'::jsonb, null, 'system');
    else
      insert into private.profile_change_events (user_id, change_kind, field)
      values (new.id, 'bio_minor', 'bio');
    end if;
  end if;

  return new;
end;
$$;

create trigger profiles_after_write_moderation
  after insert or update on public.profiles
  for each row execute function private.profiles_after_write_moderation();

-- ---------------------------------------------------------------------------
-- Risk and trust (internal only)
-- ---------------------------------------------------------------------------

create function private.risk_score(p_user_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select coalesce(sum(t.weight * case s.severity when 'high' then 4 when 'medium' then 2 else 1 end), 0)::integer
  from private.abuse_signals s
  join private.abuse_signal_types t on t.code = s.signal_type
  where s.user_id = p_user_id
    and s.review_status in ('open', 'escalated', 'confirmed')
    and s.created_at > now() - (private.settings()).risk_window
$$;

-- new | verified | established | review_required | restricted | suspended.
-- Computed on demand from server state, so it can't be stored stale or
-- forged, and "established" is lost again after big profile changes.
create function private.trust_level(p_user_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  acct private.accounts;
  verification text;
  verified_at timestamptz;
begin
  select * into acct from private.accounts where user_id = p_user_id;
  if not found then
    return 'restricted';
  end if;

  if acct.status in ('suspended', 'banned', 'deletion_pending') then
    return 'suspended';
  end if;
  if acct.status = 'restricted' or private.has_active_safety_hold(p_user_id) then
    return 'restricted';
  end if;
  if acct.manual_review_required
     or private.risk_score(p_user_id) >= cfg.review_risk_threshold then
    return 'review_required';
  end if;

  select verification_status, verification_reviewed_at into verification, verified_at
  from public.profiles where id = p_user_id;
  if verification is distinct from 'verified' then
    return 'new';
  end if;

  if acct.created_at < now() - cfg.established_after
     and not exists (
       select 1 from private.abuse_signals s
       join private.abuse_signal_types t on t.code = s.signal_type
       where s.user_id = p_user_id and s.review_status = 'open' and t.weight > 0
     )
     and not exists (
       select 1 from private.profile_change_events e
       where e.user_id = p_user_id
         and e.change_kind in ('identity', 'bio_major', 'photo')
         and e.created_at > now() - cfg.profile_change_cooldown
     ) then
    return 'established';
  end if;

  return 'verified';
end;
$$;

-- ---------------------------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------------------------

create table private.blocks (
  blocker_id  uuid not null references auth.users (id) on delete cascade,
  blocked_id  uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create index blocks_blocked_idx on private.blocks (blocked_id);

-- Symmetric: either direction excludes the pair.
create function private.is_blocked_between(p_a uuid, p_b uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from private.blocks
    where (blocker_id = p_a and blocked_id = p_b)
       or (blocker_id = p_b and blocked_id = p_a)
  )
$$;

create function public.block_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_user_id is null or p_user_id = uid then
    raise exception 'invalid block target' using errcode = 'check_violation';
  end if;
  if not private.try_consume_rate_limit('block_user', uid::text) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;
  -- Unknown IDs are ignored silently, so blocking can't probe for accounts.
  if exists (select 1 from auth.users where id = p_user_id) then
    insert into private.blocks (blocker_id, blocked_id)
    values (uid, p_user_id)
    on conflict do nothing;
  end if;
end;
$$;

create function public.unblock_user(p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from private.blocks where blocker_id = auth.uid() and blocked_id = p_user_id
$$;

-- Only blocks the caller made. Nobody can list who has blocked them.
create function public.my_blocked_users()
returns table (user_id uuid, blocked_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select blocked_id, created_at from private.blocks
  where blocker_id = auth.uid()
  order by created_at desc
$$;

-- ---------------------------------------------------------------------------
-- Discovery eligibility (server-side only)
-- ---------------------------------------------------------------------------

-- Reasons are internal codes. Callers outside the server get only the
-- coarse version from public.get_my_discovery_eligibility().
create function private.discovery_ineligibility_reasons(p_user_id uuid)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  reasons text[] := '{}';
  confirmed timestamptz;
  prof record;
  trust text;
begin
  select email_confirmed_at into confirmed from auth.users where id = p_user_id;
  if confirmed is null then
    reasons := array_append(reasons, 'email_unconfirmed');
  end if;

  select profile_completed, verification_status, birth_date into prof
  from public.profiles where id = p_user_id;
  if not found or not prof.profile_completed then
    reasons := array_append(reasons, 'profile_incomplete');
  end if;
  -- Re-checked here, not only when the profile was saved.
  if prof.birth_date is null
     or extract(year from age((now() at time zone 'utc')::date, prof.birth_date)) < 18 then
    reasons := array_append(reasons, 'age_requirement');
  end if;
  if prof.verification_status is distinct from 'verified' then
    reasons := array_append(reasons, 'verification_required');
  end if;

  if (select status from private.accounts where user_id = p_user_id) is distinct from 'active' then
    reasons := array_append(reasons, 'account_not_active');
  end if;

  trust := private.trust_level(p_user_id);
  if trust in ('review_required', 'restricted', 'suspended') then
    reasons := array_append(reasons, 'trust_' || trust);
  end if;
  if private.has_active_safety_hold(p_user_id) then
    reasons := array_append(reasons, 'safety_hold');
  end if;

  return reasons;
end;
$$;

create function private.is_discovery_eligible(p_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select cardinality(private.discovery_ineligibility_reasons(p_user_id)) = 0
$$;

-- Future Discovery, likes, matches and messages must all go through this.
create function private.can_interact(p_actor uuid, p_target uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_actor <> p_target
     and private.is_discovery_eligible(p_actor)
     and private.is_discovery_eligible(p_target)
     and not private.is_blocked_between(p_actor, p_target)
$$;

-- For the signed-in user only. Internal reasons are collapsed so review,
-- risk and safety details are never revealed.
create function public.get_my_discovery_eligibility()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  internal text[];
  visible text[] := '{}';
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;
  internal := private.discovery_ineligibility_reasons(uid);
  if 'email_unconfirmed' = any (internal) then visible := array_append(visible, 'email_unconfirmed'); end if;
  if 'profile_incomplete' = any (internal) or 'age_requirement' = any (internal) then
    visible := array_append(visible, 'profile_incomplete');
  end if;
  if 'verification_required' = any (internal) then visible := array_append(visible, 'verification_required'); end if;
  if internal && array['account_not_active', 'trust_review_required', 'trust_restricted',
                       'trust_suspended', 'safety_hold'] then
    visible := array_append(visible, 'account_unavailable');
  end if;
  return jsonb_build_object('eligible', cardinality(internal) = 0, 'reasons', to_jsonb(visible));
end;
$$;

-- ---------------------------------------------------------------------------
-- Reports
-- ---------------------------------------------------------------------------

create table private.report_categories (
  code              text primary key check (code ~ '^[a-z][a-z0-9_]{0,59}$'),
  priority          text not null check (priority in ('normal', 'high', 'urgent', 'critical')),
  is_child_safety   boolean not null default false,
  description       text not null
);

insert into private.report_categories (code, priority, is_child_safety, description) values
  ('fake_profile',          'normal', false, 'Fake profile'),
  ('impersonation',         'high',   false, 'Pretending to be someone else'),
  ('stolen_photos',         'high',   false, 'Using someone else''s photos'),
  ('selling_content',       'normal', false, 'Selling content or services'),
  ('scam_or_money_request', 'high',   false, 'Scam or asking for money'),
  ('spam',                  'normal', false, 'Spam'),
  ('underage_concern',      'urgent', true,  'May be under 18'),
  ('harassment',            'high',   false, 'Harassment'),
  ('hate_or_threats',       'urgent', false, 'Hate speech or threats'),
  ('other',                 'normal', false, 'Something else');

create table private.user_reports (
  id                uuid primary key default gen_random_uuid(),
  -- Never exposed to the reported user or anyone outside moderation.
  reporter_id       uuid not null,
  reported_user_id  uuid not null,
  category          text not null references private.report_categories (code),
  priority          text not null,
  details           text check (char_length(details) <= 1000),
  status            text not null default 'open'
    check (status in ('open', 'in_review', 'actioned', 'dismissed')),
  created_at        timestamptz not null default now(),
  reviewed_at       timestamptz,
  reviewer_id       uuid,
  resolution_note   text check (char_length(resolution_note) <= 500),
  check (reporter_id <> reported_user_id)
);

create index user_reports_queue_idx
  on private.user_reports (priority, created_at)
  where status in ('open', 'in_review');
create index user_reports_reported_idx on private.user_reports (reported_user_id, created_at desc);
create index user_reports_reporter_idx on private.user_reports (reporter_id, created_at desc);

-- Reporter and report content are fixed once submitted; only review fields
-- change, and only through moderation functions.
create function private.user_reports_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.reporter_id <> old.reporter_id
     or new.reported_user_id <> old.reported_user_id
     or new.category <> old.category
     or new.details is distinct from old.details
     or new.created_at <> old.created_at then
    raise exception 'report contents are immutable' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger user_reports_guard
  before update on private.user_reports
  for each row execute function private.user_reports_guard();

-- Submit a report. Returns the report id. Reporting an unknown user, or the
-- same person twice for the same reason while open, is accepted without
-- revealing anything.
create function public.submit_report(
  p_reported_user_id uuid,
  p_category text,
  p_details text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  cat private.report_categories;
  existing uuid;
  new_id uuid;
  distinct_reporters integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into cat from private.report_categories where code = p_category;
  if not found then
    raise exception 'invalid report category' using errcode = 'check_violation';
  end if;
  if p_reported_user_id is null or p_reported_user_id = uid then
    raise exception 'invalid report target' using errcode = 'check_violation';
  end if;
  if not private.try_consume_rate_limit('report_submit', uid::text) then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  if not exists (select 1 from auth.users where id = p_reported_user_id) then
    return gen_random_uuid();
  end if;

  select id into existing from private.user_reports
  where reporter_id = uid and reported_user_id = p_reported_user_id
    and category = p_category and status in ('open', 'in_review');
  if existing is not null then
    return existing;
  end if;

  insert into private.user_reports (reporter_id, reported_user_id, category, priority, details)
  values (uid, p_reported_user_id, p_category, cat.priority, nullif(btrim(p_details), ''))
  returning id into new_id;

  -- Child-safety categories are handled by their own pipeline (see the
  -- child-safety migration) and don't create ordinary signals.
  if not cat.is_child_safety then
    select count(distinct reporter_id) into distinct_reporters
    from private.user_reports
    where reported_user_id = p_reported_user_id
      and created_at > now() - interval '30 days';
    perform private.record_abuse_signal(
      p_reported_user_id, 'user_report',
      case when distinct_reporters >= 3 then 'high' when distinct_reporters = 2 then 'medium' else 'low' end,
      jsonb_build_object('category', p_category), null, 'user_report');
  end if;

  return new_id;
end;
$$;

-- The reporter's own reports and their status. Contains nothing about the
-- reported person beyond what the reporter already knows.
create function public.my_submitted_reports()
returns table (report_id uuid, reported_user_id uuid, category text, status text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select id, reported_user_id, category,
         case when status in ('actioned', 'dismissed') then 'reviewed' else 'received' end,
         created_at
  from private.user_reports
  where reporter_id = auth.uid()
  order by created_at desc
$$;

-- ---------------------------------------------------------------------------
-- Moderation actions (append-only)
-- ---------------------------------------------------------------------------

create table private.moderation_actions (
  id              bigint generated always as identity primary key,
  target_user_id  uuid not null,
  action          text not null check (action in (
    'dismiss', 'warn', 'restrict', 'suspend', 'ban', 'require_reverification',
    'lift_restriction', 'clear_review'
  )),
  reason          text check (char_length(reason) <= 500),
  report_id       uuid,
  moderator_id    uuid not null,
  created_at      timestamptz not null default now()
);

create index moderation_actions_target_idx
  on private.moderation_actions (target_user_id, created_at desc);

create trigger moderation_actions_append_only
  before update or delete on private.moderation_actions
  for each row execute function private.forbid_modification();

-- Moderator entry point. Needs the moderator role claim and MFA.
create function public.moderate_user(
  p_user_id uuid,
  p_action text,
  p_reason text,
  p_report_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  moderator constant uuid := auth.uid();
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_user_id = moderator then
    raise exception 'moderators cannot act on their own account' using errcode = 'insufficient_privilege';
  end if;

  insert into private.moderation_actions (target_user_id, action, reason, report_id, moderator_id)
  values (p_user_id, p_action, p_reason, p_report_id, moderator);

  case p_action
    when 'restrict' then
      perform private.set_account_status(p_user_id, 'restricted', p_reason, 'moderator', moderator);
    when 'suspend' then
      perform private.set_account_status(p_user_id, 'suspended', p_reason, 'moderator', moderator);
    when 'ban' then
      perform private.set_account_status(p_user_id, 'banned', p_reason, 'moderator', moderator);
    when 'lift_restriction' then
      perform private.set_account_status(p_user_id, 'active', p_reason, 'moderator', moderator);
    when 'require_reverification' then
      perform private.set_verification_status(p_user_id, 'reverification_required');
      perform private.log_verification_event(
        'verification_revoked', p_user_id, null, 'moderator', moderator,
        jsonb_build_object('reason', left(coalesce(p_reason, ''), 200)));
    when 'clear_review' then
      update private.accounts
      set manual_review_required = false, review_reason = null
      where user_id = p_user_id;
      update private.abuse_signals
      set review_status = 'dismissed', reviewed_at = now(), reviewer_id = moderator
      where user_id = p_user_id and review_status = 'open';
    else
      null; -- dismiss / warn: recorded only
  end case;

  if p_report_id is not null then
    update private.user_reports
    set status = case when p_action = 'dismiss' then 'dismissed' else 'actioned' end,
        reviewed_at = now(), reviewer_id = moderator, resolution_note = left(p_reason, 500)
    where id = p_report_id
      and reported_user_id = p_user_id
      and category not in (select code from private.report_categories where is_child_safety);
  end if;
end;
$$;

create function public.review_abuse_signal(p_signal_id bigint, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_status not in ('dismissed', 'confirmed', 'escalated') then
    raise exception 'invalid status' using errcode = 'check_violation';
  end if;
  update private.abuse_signals
  set review_status = p_status, reviewed_at = now(), reviewer_id = auth.uid()
  where id = p_signal_id and user_id <> auth.uid();
end;
$$;

-- ---------------------------------------------------------------------------
-- Rate limits for future likes, conversations and messages
-- ---------------------------------------------------------------------------

insert into private.rate_limit_rules (action, max_events, per_window, description) values
  ('like',                               200, interval '1 day', 'Likes per day'),
  ('like_new_account',                   50,  interval '1 day', 'Likes per day for new accounts'),
  ('conversation_create',                50,  interval '1 day', 'New conversations per day'),
  ('conversation_create_new_account',    10,  interval '1 day', 'New conversations per day for new accounts'),
  ('first_message',                      100, interval '1 day', 'First messages per day'),
  ('first_message_new_account',          20,  interval '1 day', 'First messages per day for new accounts'),
  ('external_link_message',              20,  interval '1 day', 'Messages with links per day'),
  ('external_link_message_new_account',  3,   interval '1 day', 'Messages with links per day for new accounts'),
  ('report_submit',                      20,  interval '1 day', 'Reports a user can submit per day'),
  ('block_user',                         100, interval '1 day', 'Blocks per day');

-- Uses the stricter `<action>_new_account` rule while an account is new.
create function private.consume_user_action(p_user_id uuid, p_action text)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  is_new boolean;
begin
  select a.created_at > now() - (private.settings()).new_account_period
    into is_new
  from private.accounts a where a.user_id = p_user_id;

  if coalesce(is_new, true)
     and exists (select 1 from private.rate_limit_rules where action = p_action || '_new_account') then
    return private.try_consume_rate_limit(p_action || '_new_account', p_user_id::text);
  end if;
  return private.try_consume_rate_limit(p_action, p_user_id::text);
end;
$$;

-- ---------------------------------------------------------------------------
-- Message-abuse primitives (for the future messaging backend)
-- ---------------------------------------------------------------------------
-- Only a keyed hash of the normalised text is kept, for a short time, to
-- spot copy-paste blasts. Message content itself is never stored here.

create table private.message_fingerprint_events (
  id            bigint generated always as identity primary key,
  sender_id     uuid not null,
  recipient_id  uuid not null,
  fingerprint   text not null,
  has_link      boolean not null default false,
  created_at    timestamptz not null default now()
);

create index message_fingerprint_events_idx
  on private.message_fingerprint_events (sender_id, fingerprint, created_at desc);

create function private.check_outbound_message(
  p_sender uuid,
  p_recipient uuid,
  p_body text,
  p_is_first_message boolean
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  fp text;
  hits text[];
  has_link boolean;
  recipients integer;
  signals text[] := '{}';
begin
  if not private.can_interact(p_sender, p_recipient) then
    return jsonb_build_object('allowed', false, 'reason', 'not_allowed');
  end if;
  if p_is_first_message and not private.consume_user_action(p_sender, 'first_message') then
    perform private.record_abuse_signal(p_sender, 'first_message_velocity', 'medium', '{}'::jsonb, null, 'rate_limit');
    return jsonb_build_object('allowed', false, 'reason', 'rate_limited');
  end if;

  select coalesce(array_agg(signal_type), '{}') into hits from private.scan_text(p_body);
  has_link := 'external_link' = any (hits);
  if has_link and not private.consume_user_action(p_sender, 'external_link_message') then
    perform private.record_abuse_signal(p_sender, 'repeated_external_links', 'medium', '{}'::jsonb, null, 'rate_limit');
    return jsonb_build_object('allowed', false, 'reason', 'rate_limited');
  end if;

  fp := private.hash_identifier(regexp_replace(lower(coalesce(p_body, '')), '[[:space:]]+', ' ', 'g'));
  insert into private.message_fingerprint_events (sender_id, recipient_id, fingerprint, has_link)
  values (p_sender, p_recipient, fp, has_link);

  select count(distinct recipient_id) into recipients
  from private.message_fingerprint_events
  where sender_id = p_sender and fingerprint = fp and created_at > now() - interval '1 day';
  if recipients >= cfg.duplicate_message_recipients then
    perform private.record_abuse_signal(
      p_sender, 'duplicate_message_blast',
      case when recipients >= cfg.duplicate_message_recipients * 4 then 'high' else 'medium' end,
      jsonb_build_object('recipients', recipients), null, 'message_scan');
    signals := array_append(signals, 'duplicate_message_blast');
  end if;

  if p_is_first_message and hits && array[
       'payment_handle', 'paid_content_solicitation', 'money_request',
       'commercial_sexual_content', 'price_list_pattern', 'off_platform_redirect',
       'subscription_promotion'] then
    perform private.record_abuse_signal(
      p_sender, 'immediate_commercial_solicitation', 'high', '{}'::jsonb, null, 'message_scan');
    signals := array_append(signals, 'immediate_commercial_solicitation');
  end if;

  perform private.scan_user_text(p_sender, 'message', p_body, 'message_scan');

  -- Content signals feed review; they don't block delivery on their own.
  return jsonb_build_object('allowed', true, 'signals', to_jsonb(signals || hits));
end;
$$;

create function private.purge_message_fingerprints()
returns integer
language sql
set search_path = ''
as $$
  with deleted as (
    delete from private.message_fingerprint_events
    where created_at < now() - (private.settings()).message_fingerprint_retention
    returning 1
  )
  select count(*)::integer from deleted
$$;

-- ---------------------------------------------------------------------------
-- Media assets and duplicate-image foundation
-- ---------------------------------------------------------------------------
-- For future public profile photos and message attachments. A trusted
-- backend computes hashes at upload: SHA-256 for exact copies and a 64-bit
-- perceptual hash (e.g. dHash/pHash) for near-duplicates. These describe the
-- image, not a face: no facial recognition, embeddings or templates.

create table private.media_assets (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references auth.users (id) on delete cascade,
  purpose           text not null check (purpose in ('profile_photo', 'message_attachment')),
  bucket_id         text not null,
  object_path       text not null,
  moderation_state  text not null default 'pending_scan' check (moderation_state in (
    'pending_scan', 'approved', 'rejected', 'quarantined', 'removed'
  )),
  sha256            text check (sha256 ~ '^[0-9a-f]{64}$'),
  perceptual_hash   bit(64),
  created_at        timestamptz not null default now(),
  scanned_at        timestamptz,
  published_at      timestamptz,
  unique (bucket_id, object_path)
);

create index media_assets_owner_idx on private.media_assets (owner_id);
create index media_assets_sha_idx on private.media_assets (sha256) where sha256 is not null;

-- Identity of a media row is fixed once set, so review can't be bypassed by
-- swapping the underlying object. Leaving quarantine is reserved for the
-- child-safety release function.
create function private.media_assets_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.owner_id <> old.owner_id
     or new.bucket_id <> old.bucket_id
     or new.object_path <> old.object_path
     or (old.sha256 is not null and new.sha256 is distinct from old.sha256)
     or (old.perceptual_hash is not null and new.perceptual_hash is distinct from old.perceptual_hash) then
    raise exception 'media identity is immutable' using errcode = 'insufficient_privilege';
  end if;
  if old.moderation_state = 'quarantined'
     and new.moderation_state <> 'quarantined'
     and coalesce(current_setting('app.child_safety_release', true), '') <> 'on' then
    raise exception 'quarantined media can only be released by child-safety review'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger media_assets_guard
  before update on private.media_assets
  for each row execute function private.media_assets_guard();

-- Called by the trusted upload backend (service role) with the hashes it
-- computed. Flags reuse of another account's public image.
create function private.register_media_hashes(
  p_asset_id uuid,
  p_sha256 text,
  p_perceptual_hash bit(64)
)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  asset private.media_assets;
  match record;
  matches integer := 0;
begin
  update private.media_assets
  set sha256 = p_sha256, perceptual_hash = p_perceptual_hash, scanned_at = now()
  where id = p_asset_id
  returning * into asset;
  if not found or asset.purpose <> 'profile_photo' then
    return 0;
  end if;

  for match in
    select distinct owner_id from private.media_assets
    where purpose = 'profile_photo'
      and owner_id <> asset.owner_id
      and moderation_state in ('approved', 'pending_scan')
      and (sha256 = p_sha256
           or (perceptual_hash is not null
               and bit_count(perceptual_hash # p_perceptual_hash) <= cfg.near_duplicate_image_distance))
  loop
    perform private.record_abuse_signal(
      asset.owner_id, 'reused_public_image', 'medium',
      jsonb_build_object('asset_id', asset.id), match.owner_id, 'media_scan');
    matches := matches + 1;
  end loop;

  if matches > 0 then
    insert into private.profile_change_events (user_id, change_kind, field)
    values (asset.owner_id, 'photo', 'profile_photo');
  end if;
  return matches;
end;
$$;

-- Whether media may be shown to other users: approved, not quarantined, and
-- the owner is visible (eligible, no safety hold).
create function private.media_is_publicly_servable(p_asset_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from private.media_assets m
    where m.id = p_asset_id
      and m.moderation_state = 'approved'
      and m.purpose = 'profile_photo'
      and not private.has_active_safety_hold(m.owner_id)
      and private.is_discovery_eligible(m.owner_id)
  )
$$;

-- The only user-facing way to resolve a media reference. Returns the object
-- path (never a URL) for servable media, only to eligible viewers who aren't
-- blocked by the owner; otherwise null.
create function public.resolve_public_media(p_asset_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select m.object_path
  from private.media_assets m
  where m.id = p_asset_id
    and auth.uid() is not null
    and (auth.uid() = m.owner_id or private.is_discovery_eligible(auth.uid()))
    and private.media_is_publicly_servable(m.id)
    and not private.is_blocked_between(auth.uid(), m.owner_id)
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke all on all tables in schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_write_verification_object(text) to authenticated;
grant execute on function private.owns_verification_object(text) to authenticated;

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.block_user(uuid)',
    'public.unblock_user(uuid)',
    'public.my_blocked_users()',
    'public.get_my_discovery_eligibility()',
    'public.submit_report(uuid, text, text)',
    'public.my_submitted_reports()',
    'public.moderate_user(uuid, text, text, uuid)',
    'public.review_abuse_signal(bigint, text)',
    'public.resolve_public_media(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;
