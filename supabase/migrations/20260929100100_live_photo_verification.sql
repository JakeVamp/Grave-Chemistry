-- Grave Chemistry: live photo verification foundation
--
-- Creates:
--   * verification status on profiles (public, server-controlled) plus a
--     derived `verified_badge` column
--   * private verification sessions with server-chosen liveness challenges
--   * an append-only verification audit log
--   * a private Storage bucket for verification photos, with policies that
--     only allow uploading into the caller's own open session
--   * RPCs: start/submit (users), review (moderators), provider result
--     (service role), reverification (moderators)
--   * retention helpers for deleting media on a schedule
--
-- The approval path never runs in the Flutter client. Uploading a photo
-- only ever moves a user to `pending`.
--
-- No biometric data (face embeddings, templates, similarity scores) is
-- stored here.

-- ---------------------------------------------------------------------------
-- Public verification state on profiles
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column verification_status text not null default 'not_started'
    check (verification_status in (
      'not_started', 'pending', 'verified', 'rejected', 'expired', 'reverification_required'
    )),
  add column verification_submitted_at timestamptz,
  add column verification_reviewed_at timestamptz,
  add column verification_method text
    check (verification_method in ('manual_review', 'provider')),
  -- The only thing other users will ever learn about verification. Derived,
  -- so it can't be written directly by anyone.
  add column verified_badge boolean
    generated always as (verification_status = 'verified') stored;

comment on column public.profiles.verification_status is
  'Server-controlled. Changed only by verification RPCs, never by clients.';

-- Clients were never granted write access to these columns (the profiles
-- migration uses column-level grants). The trigger below adds a second
-- layer so a future grant mistake still can't let a user verify themselves.
create or replace function public.profiles_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  minimum_age constant integer := 18;
  today_utc constant date := (now() at time zone 'utc')::date;
  client_write constant boolean := current_user in ('authenticated', 'anon');
begin
  if tg_op = 'UPDATE' then
    new.id := old.id;
    new.created_at := old.created_at;
    if client_write then
      new.verification_status := old.verification_status;
      new.verification_submitted_at := old.verification_submitted_at;
      new.verification_reviewed_at := old.verification_reviewed_at;
      new.verification_method := old.verification_method;
    end if;
  else
    new.created_at := now();
    if client_write then
      new.verification_status := 'not_started';
      new.verification_submitted_at := null;
      new.verification_reviewed_at := null;
      new.verification_method := null;
    end if;
  end if;
  new.updated_at := now();

  if new.birth_date is not null then
    if new.birth_date > today_utc then
      raise exception using
        errcode = 'check_violation',
        message = 'birth_date_in_future',
        detail = 'Birth date cannot be in the future.';
    end if;

    if extract(year from age(today_utc, new.birth_date)) < minimum_age then
      raise exception using
        errcode = 'check_violation',
        message = 'under_minimum_age',
        detail = format('Users must be at least %s years old.', minimum_age);
    end if;
  end if;

  new.profile_completed :=
        new.display_name is not null
    and new.birth_date is not null
    and new.location_city is not null
    and new.location_state_or_region is not null
    and new.gender is not null
    and (new.gender <> 'self_describe' or new.gender_self_description is not null)
    and new.community_identity is not null
    and new.dating_preference is not null;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Challenges and sessions (private)
-- ---------------------------------------------------------------------------

create table private.verification_challenges (
  code         text primary key check (code ~ '^[a-z][a-z0-9_]{0,39}$'),
  instruction  text not null,
  is_active    boolean not null default true
);

insert into private.verification_challenges (code, instruction) values
  ('look_straight',   'Look straight at the camera'),
  ('turn_head_left',  'Turn your head slightly to the left'),
  ('turn_head_right', 'Turn your head slightly to the right'),
  ('blink',           'Blink while taking the photo'),
  ('smile',           'Smile');

create table private.verification_sessions (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  status              text not null default 'issued' check (status in (
    'issued',      -- waiting for a photo
    'submitted',   -- photo received, awaiting review
    'approved',
    'rejected',
    'expired',     -- not submitted in time
    'superseded'   -- replaced by a newer session before submission
  )),
  challenge_type      text not null references private.verification_challenges (code),
  attempt_number      integer not null check (attempt_number >= 1),
  created_at          timestamptz not null default now(),
  expires_at          timestamptz not null,
  submitted_at        timestamptz,

  -- Review outcome. Set only by moderator / provider paths.
  reviewed_at         timestamptz,
  review_actor_type   text check (review_actor_type in ('system', 'moderator')),
  reviewer_id         uuid,
  decision_reason     text check (char_length(decision_reason) <= 500),
  verification_method text check (verification_method in ('manual_review', 'provider')),
  provider_reference  text check (char_length(provider_reference) <= 200),
  liveness_result     text check (liveness_result in ('passed', 'failed', 'inconclusive')),

  -- Device attestation (App Attest / Play Integrity), recorded by a trusted
  -- backend before submission once enabled.
  attestation_status   text not null default 'not_provided'
    check (attestation_status in ('not_provided', 'valid', 'invalid')),
  attestation_provider text check (attestation_provider in ('app_attest', 'device_check', 'play_integrity')),
  attested_at          timestamptz,

  -- Evidence. A Storage object path, never a URL.
  media_object_path   text unique,
  media_retain_until  timestamptz,
  media_deleted_at    timestamptz,

  check (expires_at > created_at)
);

create index verification_sessions_user_idx
  on private.verification_sessions (user_id, created_at desc);

-- At most one open session per user.
create unique index verification_sessions_one_issued_idx
  on private.verification_sessions (user_id)
  where status = 'issued';

create index verification_sessions_media_retention_idx
  on private.verification_sessions (media_retain_until)
  where media_object_path is not null and media_deleted_at is null;

-- ---------------------------------------------------------------------------
-- Audit log (append-only)
-- ---------------------------------------------------------------------------

create table private.verification_audit_log (
  id          bigint generated always as identity primary key,
  event_type  text not null check (event_type in (
    'verification_requested',
    'challenge_issued',
    'photo_submitted',
    'submission_failed',
    'approved',
    'rejected',
    'retry_requested',
    'session_expired',
    'verification_revoked',
    'media_deleted'
  )),
  -- Deliberately no foreign keys: history must outlive the account.
  user_id     uuid not null,
  session_id  uuid,
  actor_type  text not null check (actor_type in ('user', 'system', 'moderator')),
  actor_id    uuid,
  created_at  timestamptz not null default now(),
  -- Small, non-sensitive context only (reason codes). Never image data,
  -- URLs, tokens or object paths.
  details     jsonb not null default '{}'::jsonb
    check (pg_column_size(details) <= 2048)
);

create index verification_audit_log_user_idx
  on private.verification_audit_log (user_id, created_at desc);

create trigger verification_audit_log_append_only
  before update or delete on private.verification_audit_log
  for each row execute function private.forbid_modification();

create function private.log_verification_event(
  p_event_type text,
  p_user_id uuid,
  p_session_id uuid,
  p_actor_type text,
  p_actor_id uuid default null,
  p_details jsonb default '{}'::jsonb
)
returns void
language sql
set search_path = ''
as $$
  insert into private.verification_audit_log
    (event_type, user_id, session_id, actor_type, actor_id, details)
  values (p_event_type, p_user_id, p_session_id, p_actor_type, p_actor_id, coalesce(p_details, '{}'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- Status transitions
-- ---------------------------------------------------------------------------

create function private.set_verification_status(
  p_user_id uuid,
  p_new_status text,
  p_method text default null
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  current_status text;
begin
  select verification_status into current_status
  from public.profiles where id = p_user_id for update;
  if not found then
    raise exception 'profile not found';
  end if;

  if not (
       (current_status in ('not_started', 'rejected', 'expired', 'reverification_required')
          and p_new_status = 'pending')
    or (current_status = 'pending' and p_new_status in ('verified', 'rejected'))
    or (current_status = 'verified' and p_new_status in ('reverification_required', 'expired'))
  ) then
    raise exception 'invalid_verification_transition: % -> %', current_status, p_new_status
      using errcode = 'check_violation';
  end if;

  update public.profiles
  set verification_status = p_new_status,
      verification_submitted_at = case
        when p_new_status = 'pending' then now() else verification_submitted_at end,
      verification_reviewed_at = case
        when p_new_status in ('verified', 'rejected') then now() else verification_reviewed_at end,
      verification_method = coalesce(p_method, verification_method)
  where id = p_user_id;
end;
$$;

create function private.expire_verification_sessions(p_user_id uuid default null)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  expired record;
  total integer := 0;
begin
  for expired in
    update private.verification_sessions
    set status = 'expired',
        media_retain_until = now() + (private.settings()).retain_abandoned_media
    where status = 'issued'
      and expires_at <= now()
      and (p_user_id is null or user_id = p_user_id)
    returning id, user_id
  loop
    perform private.log_verification_event('session_expired', expired.user_id, expired.id, 'system');
    total := total + 1;
  end loop;
  return total;
end;
$$;

-- ---------------------------------------------------------------------------
-- User RPCs
-- ---------------------------------------------------------------------------

-- Starts a verification session. The server picks the challenge; the client
-- only displays it. Returns {outcome, ...}; expected refusals are outcomes,
-- not errors, so they can be audited.
create function public.start_verification_session()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  cfg private.security_settings := private.settings();
  profile_row record;
  recent_rejections integer;
  chosen_challenge text;
  next_attempt integer;
  session_row private.verification_sessions;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;

  perform private.expire_verification_sessions(uid);

  select profile_completed, verification_status into profile_row
  from public.profiles where id = uid for update;

  if not found or not profile_row.profile_completed then
    return jsonb_build_object('outcome', 'profile_incomplete');
  end if;
  if profile_row.verification_status = 'pending' then
    return jsonb_build_object('outcome', 'already_submitted');
  end if;
  if profile_row.verification_status = 'verified' then
    return jsonb_build_object('outcome', 'already_verified');
  end if;

  select count(*) into recent_rejections
  from private.verification_sessions
  where user_id = uid
    and status = 'rejected'
    and reviewed_at > now() - cfg.verification_rejection_window;
  if recent_rejections >= cfg.max_verification_rejections then
    return jsonb_build_object('outcome', 'too_many_attempts');
  end if;

  if not private.try_consume_rate_limit('verification_session_start_hourly', uid::text)
     or not private.try_consume_rate_limit('verification_session_start_daily', uid::text) then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;

  update private.verification_sessions
  set status = 'superseded',
      media_retain_until = now() + cfg.retain_abandoned_media
  where user_id = uid and status = 'issued';

  select code into chosen_challenge
  from private.verification_challenges
  where is_active
  order by random()
  limit 1;

  select coalesce(max(attempt_number), 0) + 1 into next_attempt
  from private.verification_sessions where user_id = uid;

  insert into private.verification_sessions
    (user_id, challenge_type, attempt_number, expires_at)
  values (uid, chosen_challenge, next_attempt, now() + cfg.verification_session_ttl)
  returning * into session_row;

  perform private.log_verification_event(
    case when profile_row.verification_status = 'not_started'
      then 'verification_requested' else 'retry_requested' end,
    uid, session_row.id, 'user', uid);
  perform private.log_verification_event(
    'challenge_issued', uid, session_row.id, 'system', null,
    jsonb_build_object('challenge', chosen_challenge));

  return jsonb_build_object(
    'outcome', 'issued',
    'session_id', session_row.id,
    'challenge_type', session_row.challenge_type,
    'expires_at', session_row.expires_at,
    'attempt_number', session_row.attempt_number
  );
end;
$$;

-- Submits the photo already uploaded to `<session_id>/<random>.jpg`.
-- On success the profile becomes `pending` — never `verified`.
create function public.submit_verification_session(p_session_id uuid, p_object_path text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  cfg private.security_settings := private.settings();
  session_row private.verification_sessions;
  profile_status text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;

  select * into session_row
  from private.verification_sessions
  where id = p_session_id
  for update;

  -- Someone else's session looks exactly like a missing one.
  if not found or session_row.user_id <> uid then
    perform private.log_verification_event(
      'submission_failed', uid, null, 'user', uid,
      jsonb_build_object('reason', 'session_not_found'));
    return jsonb_build_object('outcome', 'session_not_found');
  end if;

  if session_row.status = 'issued' and session_row.expires_at <= now() then
    perform private.expire_verification_sessions(uid);
    perform private.log_verification_event(
      'submission_failed', uid, session_row.id, 'user', uid,
      jsonb_build_object('reason', 'session_expired'));
    return jsonb_build_object('outcome', 'session_expired');
  end if;

  if session_row.status <> 'issued' then
    perform private.log_verification_event(
      'submission_failed', uid, session_row.id, 'user', uid,
      jsonb_build_object('reason', 'session_not_open'));
    return jsonb_build_object('outcome', 'session_not_open');
  end if;

  if cfg.attestation_required and session_row.attestation_status <> 'valid' then
    perform private.log_verification_event(
      'submission_failed', uid, session_row.id, 'user', uid,
      jsonb_build_object('reason', 'attestation_required'));
    return jsonb_build_object('outcome', 'attestation_required');
  end if;

  if p_object_path is null
     or split_part(p_object_path, '/', 1) <> session_row.id::text
     or p_object_path !~ '^[0-9a-f-]{36}/[0-9a-f]{32}\.jpg$'
     or not exists (
       select 1 from storage.objects
       where bucket_id = 'verification-media'
         and name = p_object_path
         and owner_id = uid::text
     ) then
    perform private.log_verification_event(
      'submission_failed', uid, session_row.id, 'user', uid,
      jsonb_build_object('reason', 'media_missing'));
    return jsonb_build_object('outcome', 'media_missing');
  end if;

  if not private.try_consume_rate_limit('verification_submit', uid::text) then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;

  select verification_status into profile_status
  from public.profiles where id = uid for update;
  if profile_status not in ('not_started', 'rejected', 'expired', 'reverification_required') then
    return jsonb_build_object('outcome', 'already_submitted');
  end if;

  update private.verification_sessions
  set status = 'submitted',
      submitted_at = now(),
      media_object_path = p_object_path,
      verification_method = cfg.verification_method
  where id = session_row.id;

  perform private.set_verification_status(uid, 'pending', cfg.verification_method);
  perform private.log_verification_event('photo_submitted', uid, session_row.id, 'user', uid);

  return jsonb_build_object('outcome', 'submitted', 'verification_status', 'pending');
end;
$$;

-- ---------------------------------------------------------------------------
-- Trusted review paths
-- ---------------------------------------------------------------------------

create function private.decide_verification_session(
  p_session_id uuid,
  p_decision text,
  p_reason text,
  p_actor_type text,
  p_actor_id uuid,
  p_liveness_result text default null,
  p_provider_reference text default null
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  session_row private.verification_sessions;
  rejections integer;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'invalid decision';
  end if;

  select * into session_row
  from private.verification_sessions where id = p_session_id for update;
  if not found or session_row.status <> 'submitted' then
    raise exception 'session is not awaiting review';
  end if;

  update private.verification_sessions
  set status = p_decision,
      reviewed_at = now(),
      review_actor_type = p_actor_type,
      reviewer_id = p_actor_id,
      decision_reason = p_reason,
      liveness_result = coalesce(p_liveness_result, liveness_result),
      provider_reference = coalesce(p_provider_reference, provider_reference),
      media_retain_until = now() + case p_decision
        when 'approved' then cfg.retain_approved_media
        else cfg.retain_rejected_media end
  where id = p_session_id;

  perform private.set_verification_status(
    session_row.user_id,
    case p_decision when 'approved' then 'verified' else 'rejected' end);

  perform private.log_verification_event(
    p_decision, session_row.user_id, p_session_id, p_actor_type, p_actor_id);

  if p_decision = 'approved' then
    if (select status from private.accounts where user_id = session_row.user_id) = 'pending_verification' then
      perform private.set_account_status(
        session_row.user_id, 'active', 'verification approved', p_actor_type, p_actor_id);
    end if;
  else
    select count(*) into rejections
    from private.verification_sessions
    where user_id = session_row.user_id
      and status = 'rejected'
      and reviewed_at > now() - cfg.verification_rejection_window;
    if rejections >= cfg.max_verification_rejections then
      perform private.record_abuse_signal(
        session_row.user_id, 'repeated_verification_failure', 'medium',
        jsonb_build_object('rejections', rejections));
    end if;
  end if;
end;
$$;

-- Moderator review (requires moderator role claim and MFA).
create function public.review_verification_session(
  p_session_id uuid,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  subject uuid;
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  select user_id into subject from private.verification_sessions where id = p_session_id;
  if subject = auth.uid() then
    raise exception 'moderators cannot review their own verification'
      using errcode = 'insufficient_privilege';
  end if;
  perform private.decide_verification_session(
    p_session_id, p_decision, p_reason, 'moderator', auth.uid());
end;
$$;

-- Result from a dedicated liveness provider, delivered by a trusted backend
-- (e.g. an Edge Function verifying the provider's webhook signature) using
-- the service role. `inconclusive` leaves the session for manual review.
create function public.apply_verification_provider_result(
  p_session_id uuid,
  p_liveness_result text,
  p_provider_reference text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_liveness_result not in ('passed', 'failed', 'inconclusive') then
    raise exception 'invalid liveness result';
  end if;

  if p_liveness_result = 'inconclusive' then
    update private.verification_sessions
    set liveness_result = 'inconclusive', provider_reference = p_provider_reference
    where id = p_session_id and status = 'submitted';
    return;
  end if;

  perform private.decide_verification_session(
    p_session_id,
    case p_liveness_result when 'passed' then 'approved' else 'rejected' end,
    'provider result', 'system', null, p_liveness_result, p_provider_reference);
end;
$$;

-- Revokes a verification without deleting any history.
create function public.require_reverification(p_user_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_type text;
begin
  if private.is_moderator() then
    actor_type := 'moderator';
  elsif private.is_service_role() then
    actor_type := 'system';
  else
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;

  perform private.set_verification_status(p_user_id, 'reverification_required');
  perform private.log_verification_event(
    'verification_revoked', p_user_id, null, actor_type,
    case actor_type when 'moderator' then auth.uid() end,
    jsonb_build_object('reason', left(coalesce(p_reason, ''), 200)));
end;
$$;

-- ---------------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------------
-- A scheduled Edge Function (service role) should:
--   1. call private.verification_media_due_for_deletion(),
--   2. delete each object through the Storage API,
--   3. call private.mark_verification_media_deleted(session_id).
-- Storage objects must be deleted via the Storage API, not by deleting rows
-- from storage.objects.

create function private.verification_media_due_for_deletion(p_limit integer default 100)
returns table (session_id uuid, object_path text)
language sql
stable
set search_path = ''
as $$
  select id, media_object_path
  from private.verification_sessions
  where media_object_path is not null
    and media_deleted_at is null
    and media_retain_until is not null
    and media_retain_until <= now()
  order by media_retain_until
  limit p_limit
$$;

create function private.mark_verification_media_deleted(p_session_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  subject uuid;
begin
  update private.verification_sessions
  set media_deleted_at = now()
  where id = p_session_id and media_deleted_at is null
  returning user_id into subject;
  if subject is not null then
    perform private.log_verification_event('media_deleted', subject, p_session_id, 'system');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Storage bucket and policies
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('verification-media', 'verification-media', false, 5242880, array['image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Object names are `<session uuid>/<32 random hex chars>.jpg`: no user ID,
-- email or name, and not guessable.
create function private.can_write_verification_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- CASE guarantees the name is validated before it is cast to a UUID.
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.jpg$'
    then exists (
      select 1 from private.verification_sessions s
      where s.id = split_part(p_name, '/', 1)::uuid
        and s.user_id = auth.uid()
        and s.status = 'issued'
        and s.expires_at > now()
    )
    else false
  end
$$;

create function private.owns_verification_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.jpg$'
    then exists (
      select 1 from private.verification_sessions s
      where s.id = split_part(p_name, '/', 1)::uuid
        and s.user_id = auth.uid()
    )
    else false
  end
$$;

create policy "Verification media: upload into own open session"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'verification-media'
    and private.can_write_verification_object(name)
  );

create policy "Verification media: replace within own open session"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'verification-media'
    and private.can_write_verification_object(name)
  )
  with check (
    bucket_id = 'verification-media'
    and private.can_write_verification_object(name)
  );

create policy "Verification media: owner can read own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'verification-media'
    and private.owns_verification_object(name)
  );

-- No delete policy: media is removed by the retention job only.

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke all on all tables in schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;

-- Storage policies call these two helpers as the requesting user.
grant usage on schema private to authenticated;
grant execute on function private.can_write_verification_object(text) to authenticated;
grant execute on function private.owns_verification_object(text) to authenticated;

revoke execute on function public.start_verification_session() from public, anon;
grant execute on function public.start_verification_session() to authenticated;

revoke execute on function public.submit_verification_session(uuid, text) from public, anon;
grant execute on function public.submit_verification_session(uuid, text) to authenticated;

revoke execute on function public.review_verification_session(uuid, text, text) from public, anon;
grant execute on function public.review_verification_session(uuid, text, text) to authenticated;

revoke execute on function public.require_reverification(uuid, text) from public, anon;
grant execute on function public.require_reverification(uuid, text) to authenticated, service_role;

revoke execute on function public.apply_verification_provider_result(uuid, text, text) from public, anon, authenticated;
grant execute on function public.apply_verification_provider_result(uuid, text, text) to service_role;
