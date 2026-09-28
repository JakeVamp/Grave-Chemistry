-- Grave Chemistry: security foundation
--
-- Creates the `private` schema for server-only data, plus shared building
-- blocks used by verification and anti-abuse:
--   * security settings (one row, edited by admins in SQL)
--   * keyed hashing for identifiers (email, phone, install IDs)
--   * server-side rate limiting
--   * moderator / service-role checks based on server-controlled JWT claims
--   * account statuses
--   * duplicate-account review flags
--
-- The `private` schema must NOT be added to the Data API's exposed schemas.
-- API roles get no table privileges here; they reach this data only through
-- the SECURITY DEFINER functions defined in `public`.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Functions are executable by PUBLIC by default; never in this schema.
alter default privileges in schema private revoke execute on functions from public;
alter default privileges in schema private revoke all on tables from public;

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

create table private.security_settings (
  id boolean primary key default true check (id),

  -- Verification
  verification_session_ttl interval not null default interval '10 minutes',
  verification_method text not null default 'manual_review'
    check (verification_method in ('manual_review', 'provider')),
  -- Turn on once App Attest / Play Integrity is integrated (see docs).
  attestation_required boolean not null default false,
  max_verification_rejections integer not null default 3,
  verification_rejection_window interval not null default interval '30 days',

  -- Verification media retention, counted from the outcome.
  retain_approved_media interval not null default interval '30 days',
  retain_rejected_media interval not null default interval '30 days',
  retain_abandoned_media interval not null default interval '1 day',

  -- Anti-abuse
  recreation_cooldown interval not null default interval '7 days',
  recreation_cooldown_after_enforcement interval not null default interval '365 days',
  max_accounts_per_install integer not null default 2,
  install_reuse_window interval not null default interval '90 days'
);

insert into private.security_settings default values;

create function private.settings()
returns private.security_settings
language sql
stable
set search_path = ''
as $$
  select * from private.security_settings where id
$$;

-- ---------------------------------------------------------------------------
-- Keyed hashing for identifiers
-- ---------------------------------------------------------------------------
-- Identifiers kept for anti-abuse are stored as HMACs, never in plain text.
-- The key never leaves the database. Consider moving it to Supabase Vault.

create table private.hash_keys (
  id boolean primary key default true check (id),
  key text not null
);

insert into private.hash_keys (key)
values (encode(extensions.gen_random_bytes(32), 'hex'));

create function private.hash_identifier(value text)
returns text
language sql
stable
set search_path = ''
as $$
  select encode(
    extensions.hmac(lower(btrim(value)), (select key from private.hash_keys), 'sha256'),
    'hex'
  )
$$;

-- ---------------------------------------------------------------------------
-- Rate limiting
-- ---------------------------------------------------------------------------

create table private.rate_limit_rules (
  action       text primary key,
  max_events   integer not null check (max_events > 0),
  per_window   interval not null check (per_window > interval '0'),
  description  text not null
);

insert into private.rate_limit_rules (action, max_events, per_window, description) values
  ('verification_session_start_hourly', 5,  interval '1 hour', 'Verification sessions a user can start per hour'),
  ('verification_session_start_daily',  10, interval '1 day',  'Verification sessions a user can start per day'),
  ('verification_submit',               10, interval '1 hour', 'Verification submissions per user per hour'),
  ('signup_per_ip',                     10, interval '1 hour', 'Sign-ups per (hashed) IP address per hour; throttles, never bans'),
  ('phone_verification_attempt',        5,  interval '1 hour', 'Phone verification attempts per user per hour'),
  ('device_registration',               30, interval '1 day',  'Device registrations per user per day');

create table private.rate_limit_events (
  id           bigint generated always as identity primary key,
  action       text not null references private.rate_limit_rules (action),
  subject_key  text not null,
  created_at   timestamptz not null default now()
);

create index rate_limit_events_lookup_idx
  on private.rate_limit_events (action, subject_key, created_at desc);

-- Records an event and returns true, or returns false (recording nothing)
-- when the limit is reached. Serialised per action/subject so concurrent
-- requests can't slip past the limit.
create function private.try_consume_rate_limit(p_action text, p_subject text)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  rule private.rate_limit_rules;
  recent integer;
begin
  select * into rule from private.rate_limit_rules where action = p_action;
  if not found then
    raise exception 'unknown rate limit action: %', p_action;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_action || ':' || p_subject, 0));

  select count(*) into recent
  from private.rate_limit_events
  where action = p_action
    and subject_key = p_subject
    and created_at > now() - rule.per_window;

  if recent >= rule.max_events then
    return false;
  end if;

  insert into private.rate_limit_events (action, subject_key)
  values (p_action, p_subject);
  return true;
end;
$$;

-- For a scheduled job (pg_cron): drop events older than any window needs.
create function private.purge_rate_limit_events()
returns integer
language sql
set search_path = ''
as $$
  with deleted as (
    delete from private.rate_limit_events e
    using private.rate_limit_rules r
    where e.action = r.action
      and e.created_at < now() - r.per_window * 2
    returning 1
  )
  select count(*)::integer from deleted
$$;

-- ---------------------------------------------------------------------------
-- Trusted caller checks
-- ---------------------------------------------------------------------------
-- app_metadata can only be written with the service role (Admin API), so a
-- user cannot grant themselves a role. Moderators must also have completed
-- MFA in this session (aal2).

create function private.jwt_claims()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(auth.jwt(), '{}'::jsonb)
$$;

create function private.is_moderator()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(private.jwt_claims() -> 'app_metadata' ->> 'role', '') in ('moderator', 'admin')
     and coalesce(private.jwt_claims() ->> 'aal', '') = 'aal2'
$$;

create function private.is_service_role()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(private.jwt_claims() ->> 'role', '') = 'service_role'
$$;

-- ---------------------------------------------------------------------------
-- Account status
-- ---------------------------------------------------------------------------

create table private.accounts (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  status             text not null default 'pending_verification'
    check (status in ('active', 'pending_verification', 'restricted', 'suspended', 'deletion_pending')),
  status_reason      text check (char_length(status_reason) <= 500),
  status_changed_at  timestamptz not null default now(),
  status_changed_by  uuid,
  created_at         timestamptz not null default now()
);

-- Append-only history of status changes.
create table private.account_status_changes (
  id           bigint generated always as identity primary key,
  user_id      uuid not null,
  old_status   text,
  new_status   text not null,
  reason       text,
  actor_type   text not null check (actor_type in ('user', 'system', 'moderator')),
  actor_id     uuid,
  created_at   timestamptz not null default now()
);

create index account_status_changes_user_idx
  on private.account_status_changes (user_id, created_at desc);

create function private.forbid_modification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and current_setting('app.allow_audit_purge', true) = 'on' then
    return old;
  end if;
  raise exception '% is append-only', tg_table_name
    using errcode = 'insufficient_privilege';
end;
$$;

create trigger account_status_changes_append_only
  before update or delete on private.account_status_changes
  for each row execute function private.forbid_modification();

create function private.set_account_status(
  p_user_id uuid,
  p_status text,
  p_reason text,
  p_actor_type text,
  p_actor_id uuid
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  previous text;
begin
  select status into previous from private.accounts where user_id = p_user_id for update;
  if not found then
    raise exception 'account not found';
  end if;
  if previous = p_status then
    return;
  end if;

  update private.accounts
  set status = p_status,
      status_reason = p_reason,
      status_changed_at = now(),
      status_changed_by = p_actor_id
  where user_id = p_user_id;

  insert into private.account_status_changes
    (user_id, old_status, new_status, reason, actor_type, actor_id)
  values (p_user_id, previous, p_status, p_reason, p_actor_type, p_actor_id);
end;
$$;

create function private.create_account_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.accounts (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created_create_account
  after insert on auth.users
  for each row execute function private.create_account_for_new_user();

-- Existing users (e.g. testers) get an account row too.
insert into private.accounts (user_id)
select id from auth.users
on conflict (user_id) do nothing;

-- The signed-in user's own status. Nothing else about the account is
-- exposed.
create function public.get_my_account_status()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select status from private.accounts where user_id = auth.uid()
$$;

-- Moderators change account status; never their own.
create function public.set_account_status(p_user_id uuid, p_status text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'moderators cannot change their own account status'
      using errcode = 'insufficient_privilege';
  end if;
  perform private.set_account_status(p_user_id, p_status, p_reason, 'moderator', auth.uid());
end;
$$;

-- ---------------------------------------------------------------------------
-- Duplicate-account review flags
-- ---------------------------------------------------------------------------
-- Signals are evidence for human review, never automatic proof. Nothing in
-- this schema suspends or restricts an account because a flag was raised.

create table private.duplicate_account_flags (
  id               bigint generated always as identity primary key,
  user_id          uuid not null,
  related_user_id  uuid,
  signal_type      text not null check (signal_type in (
    'shared_install',
    'rapid_signup',
    'repeated_verification_failure',
    'account_recreation',
    'shared_phone',
    'provider_duplicate_identity',
    'shared_ip'
  )),
  severity         text not null check (severity in ('low', 'medium', 'high')),
  review_status    text not null default 'open'
    check (review_status in ('open', 'dismissed', 'confirmed', 'escalated')),
  details          jsonb not null default '{}'::jsonb
    check (pg_column_size(details) <= 4096),
  created_at       timestamptz not null default now(),
  reviewed_at      timestamptz,
  reviewer_id      uuid
);

create index duplicate_account_flags_user_idx
  on private.duplicate_account_flags (user_id, created_at desc);
create index duplicate_account_flags_open_idx
  on private.duplicate_account_flags (created_at desc)
  where review_status = 'open';

-- Records a signal, collapsing repeats of the same open signal within a day.
create function private.record_abuse_signal(
  p_user_id uuid,
  p_signal_type text,
  p_severity text,
  p_details jsonb default '{}'::jsonb,
  p_related_user_id uuid default null
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1 from private.duplicate_account_flags
    where user_id = p_user_id
      and signal_type = p_signal_type
      and review_status = 'open'
      and created_at > now() - interval '1 day'
  ) then
    return;
  end if;

  insert into private.duplicate_account_flags
    (user_id, related_user_id, signal_type, severity, details)
  values (p_user_id, p_related_user_id, p_signal_type, p_severity, coalesce(p_details, '{}'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke all on all tables in schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;

revoke execute on function public.get_my_account_status() from public, anon;
grant execute on function public.get_my_account_status() to authenticated;

revoke execute on function public.set_account_status(uuid, text, text) from public, anon;
grant execute on function public.set_account_status(uuid, text, text) to authenticated;
