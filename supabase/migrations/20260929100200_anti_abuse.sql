-- Grave Chemistry: multi-account / duplicate-account safeguards
--
-- Creates:
--   * device registrations keyed by a random per-install ID (hashed)
--   * verified-phone links, one active account per phone number (hashed)
--   * deletion records ("tombstones") holding only hashed identifiers, so
--     deleting an account doesn't immediately reset anti-abuse controls
--   * a Supabase Auth "before user created" hook that throttles sign-ups and
--     enforces the recreation cooldown
--
-- Principles:
--   * No IMEI, serial numbers, MAC addresses, advertising IDs or contacts.
--   * Identifiers are stored only as keyed hashes.
--   * Signals create review flags. Nothing here suspends an account on its
--     own, and IP addresses are used only for throttling.
--   * Email stays in Supabase Auth; it is never copied into public tables.

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

create table private.devices (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users (id) on delete cascade,
  device_platform  text not null check (device_platform in ('ios', 'android')),
  -- HMAC of a random UUID the app generates once per installation.
  install_id_hash  text not null,
  first_seen_at    timestamptz not null default now(),
  last_seen_at     timestamptz not null default now(),
  trust_status     text not null default 'unknown'
    check (trust_status in ('unknown', 'trusted', 'suspicious', 'blocked')),
  unique (user_id, install_id_hash)
);

create index devices_install_idx on private.devices (install_id_hash);

-- Registers (or refreshes) the caller's own device. A user can only ever
-- create or touch rows for themselves; the same install ID used by another
-- account produces a separate row, plus a review flag if it's shared widely.
create function public.register_device(p_install_id text, p_platform text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  cfg private.security_settings := private.settings();
  hashed text;
  linked_accounts integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_platform not in ('ios', 'android') then
    raise exception 'invalid platform' using errcode = 'check_violation';
  end if;
  -- Only app-generated random UUIDs are accepted, never hardware IDs.
  if p_install_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'invalid install id' using errcode = 'check_violation';
  end if;
  if not private.try_consume_rate_limit('device_registration', uid::text) then
    return;
  end if;

  hashed := private.hash_identifier(p_install_id);

  insert into private.devices (user_id, device_platform, install_id_hash)
  values (uid, p_platform, hashed)
  on conflict (user_id, install_id_hash)
  do update set last_seen_at = now(), device_platform = excluded.device_platform;

  select count(distinct account) into linked_accounts
  from (
    select user_id as account from private.devices
    where install_id_hash = hashed and last_seen_at > now() - cfg.install_reuse_window
    union all
    select deleted_user_id from private.account_tombstones
    where hashed = any (install_id_hashes) and deleted_at > now() - cfg.install_reuse_window
  ) accounts;

  if linked_accounts > cfg.max_accounts_per_install then
    perform private.record_abuse_signal(
      uid, 'shared_install', 'medium',
      jsonb_build_object('accounts_on_install', linked_accounts));
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Verified phone numbers
-- ---------------------------------------------------------------------------
-- Phone verification itself (sending/checking codes) is not implemented.
-- When it is, the trusted backend that confirms the code calls
-- private.link_verified_phone(). Phone numbers are never stored in profiles.

create table private.phone_identities (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users (id) on delete set null,
  phone_hash   text not null,
  status       text not null default 'active'
    check (status in ('active', 'released', 'blocked')),
  verified_at  timestamptz not null default now(),
  released_at  timestamptz,
  check (status <> 'active' or user_id is not null)
);

-- One active account per phone number, and one active phone per account.
create unique index phone_identities_one_active_account_idx
  on private.phone_identities (phone_hash) where status = 'active';
create unique index phone_identities_one_active_phone_idx
  on private.phone_identities (user_id) where status = 'active';

-- ---------------------------------------------------------------------------
-- Deletion records
-- ---------------------------------------------------------------------------
-- Minimal, hashed data kept after an account is deleted, only to stop
-- immediate fraudulent recreation. No profile content. Retention of these
-- records needs legal/privacy review (see docs).

create table private.account_tombstones (
  id                      bigint generated always as identity primary key,
  deleted_user_id         uuid not null,
  email_hash              text,
  phone_hashes            text[] not null default '{}',
  install_id_hashes       text[] not null default '{}',
  prior_account_status    text,
  had_confirmed_flags     boolean not null default false,
  deleted_at              timestamptz not null default now(),
  block_recreation_until  timestamptz not null
);

create index account_tombstones_email_idx on private.account_tombstones (email_hash);
create index account_tombstones_phone_idx on private.account_tombstones using gin (phone_hashes);
create index account_tombstones_install_idx on private.account_tombstones using gin (install_id_hashes);

-- Media from deleted accounts waiting for the retention job.
create table private.media_deletion_queue (
  id           bigint generated always as identity primary key,
  bucket_id    text not null,
  object_path  text not null,
  queued_at    timestamptz not null default now(),
  deleted_at   timestamptz
);

create function private.phone_is_blocked(p_phone_hash text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from private.account_tombstones
    where p_phone_hash = any (phone_hashes)
      and block_recreation_until > now()
  )
$$;

-- Called by a trusted backend after the user proves they own the number.
-- Returns 'linked', 'phone_in_use', 'phone_recently_used', 'rate_limited'
-- or 'invalid_phone'.
create function private.link_verified_phone(p_user_id uuid, p_phone_e164 text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  hashed text;
  other_user uuid;
begin
  if p_phone_e164 !~ '^\+[1-9][0-9]{7,14}$' then
    return 'invalid_phone';
  end if;
  if not private.try_consume_rate_limit('phone_verification_attempt', p_user_id::text) then
    return 'rate_limited';
  end if;

  hashed := private.hash_identifier(p_phone_e164);

  select user_id into other_user
  from private.phone_identities
  where phone_hash = hashed and status = 'active';

  if other_user = p_user_id then
    return 'linked';
  end if;
  if other_user is not null then
    perform private.record_abuse_signal(
      p_user_id, 'shared_phone', 'high', '{}'::jsonb, other_user);
    return 'phone_in_use';
  end if;
  if private.phone_is_blocked(hashed) then
    perform private.record_abuse_signal(
      p_user_id, 'account_recreation', 'high', jsonb_build_object('signal', 'phone'));
    return 'phone_recently_used';
  end if;

  update private.phone_identities
  set status = 'released', released_at = now()
  where user_id = p_user_id and status = 'active';

  insert into private.phone_identities (user_id, phone_hash) values (p_user_id, hashed);
  return 'linked';
end;
$$;

create function private.record_account_deletion()
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
    select 1 from private.duplicate_account_flags
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
      when confirmed or account_status in ('restricted', 'suspended')
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

create trigger on_auth_user_deleted_record_tombstone
  before delete on auth.users
  for each row execute function private.record_account_deletion();

-- Flags (but never blocks) a new account whose email matches a recently
-- deleted one after the cooldown has passed.
create function private.flag_recreated_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  previous integer;
begin
  if new.email is null then
    return new;
  end if;
  select count(*) into previous
  from private.account_tombstones
  where email_hash = private.hash_identifier(new.email)
    and deleted_at > now() - interval '180 days';
  if previous > 0 then
    perform private.record_abuse_signal(
      new.id, 'account_recreation',
      case when previous >= 3 then 'high' when previous = 2 then 'medium' else 'low' end,
      jsonb_build_object('previous_accounts', previous));
  end if;
  return new;
end;
$$;

create trigger on_auth_user_created_flag_recreation
  after insert on auth.users
  for each row execute function private.flag_recreated_account();

-- ---------------------------------------------------------------------------
-- Supabase Auth hook: before user created
-- ---------------------------------------------------------------------------
-- Enable in Dashboard → Authentication → Hooks → "Before User Created",
-- type Postgres, function public.hook_before_user_created.

create function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  email text := event -> 'user' ->> 'email';
  ip text := event -> 'metadata' ->> 'ip_address';
begin
  if email is not null and exists (
    select 1 from private.account_tombstones
    where email_hash = private.hash_identifier(email)
      and block_recreation_until > now()
  ) then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'This email address can''t be used to create a new account right now.'));
  end if;

  -- Throttle only. The IP is hashed and never used to ban anyone.
  if ip is not null
     and not private.try_consume_rate_limit('signup_per_ip', private.hash_identifier(ip)) then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 429,
      'message', 'Too many sign-up attempts. Please try again later.'));
  end if;

  return '{}'::jsonb;
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke all on all tables in schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
-- The two storage policy helpers from the verification migration stay
-- callable by signed-in users.
grant execute on function private.can_write_verification_object(text) to authenticated;
grant execute on function private.owns_verification_object(text) to authenticated;

revoke execute on function public.register_device(text, text) from public, anon;
grant execute on function public.register_device(text, text) to authenticated;

revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
