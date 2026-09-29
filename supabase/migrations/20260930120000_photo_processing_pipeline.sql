-- Grave Chemistry: profile photo processing and moderation pipeline
--
-- Every uploaded profile photo stays "in review" until a trusted backend
-- worker (Edge Function, service role) processes it:
--   validate → normalise → fingerprint → child-safety provider → moderation
--   provider → decision (made HERE, in the database)
--
-- The worker only reports facts. Approve / reject / quarantine / manual
-- review decisions, retries and idempotency are enforced by these
-- functions. The Flutter client can't call any of them.
--
-- Also adds: moderator review functions, a verification-comparison hook,
-- and the storage clean-up queue worker API.

-- ---------------------------------------------------------------------------
-- Settings and reference data
-- ---------------------------------------------------------------------------

alter table private.security_settings
  add column photo_processing_max_attempts integer not null default 5,
  add column photo_processing_lease interval not null default interval '5 minutes',
  add column min_photo_dimension integer not null default 200,
  add column max_photo_dimension integer not null default 8000,
  add column rejected_photo_retention interval not null default interval '30 days',
  add column deletion_max_attempts integer not null default 5;

alter table private.abuse_signal_types
  drop constraint abuse_signal_types_category_check,
  add constraint abuse_signal_types_category_check check (category in (
    'duplicate_account', 'fake_profile', 'commercial_solicitation', 'spam',
    'scam', 'profile_change', 'user_report', 'content_policy'
  ));

insert into private.abuse_signal_types (code, category, weight, description) values
  ('rejected_profile_photo', 'content_policy', 2, 'Profile photo rejected by moderation');

-- When a photo was approved or rejected; retention is counted from here
-- (updated_at changes on any write, so it can't be used for that).
alter table private.media_assets add column decided_at timestamptz;

-- ---------------------------------------------------------------------------
-- Processing state
-- ---------------------------------------------------------------------------
-- media_assets.moderation_state stays the source of truth for visibility
-- (awaiting_upload / pending_scan / approved / rejected / quarantined /
-- removed). This table tracks where a pending photo is in the pipeline.

create table private.photo_processing (
  photo_id               uuid primary key references private.media_assets (id) on delete cascade,
  stage                  text not null default 'uploaded' check (stage in (
    'uploaded',               -- waiting for the worker
    'processing',             -- claimed by a worker (leased)
    'awaiting_provider',      -- provider accepted the job; poll again later
    'awaiting_manual_review', -- a human must decide
    'processing_failed',      -- failed; retried with backoff until max attempts
    'completed'               -- decided (approved / rejected / quarantined)
  )),
  attempts               integer not null default 0,
  next_attempt_at        timestamptz default now(),
  lease_expires_at       timestamptz,
  worker_id              text check (char_length(worker_id) <= 100),
  validated_at           timestamptz,
  validation_error       text check (validation_error in (
    'empty', 'too_large', 'not_jpeg', 'malformed', 'undecodable', 'too_small',
    'dimensions_too_large', 'size_mismatch', 'wrong_path', 'missing_object'
  )),
  image_width            integer,
  image_height           integer,
  byte_size              integer,
  child_safety_result    text check (child_safety_result in (
    'clear', 'possible_match', 'confirmed_known_hash_match', 'provider_error',
    'manual_review_required', 'pending'
  )),
  moderation_result      text check (moderation_result in ('approve', 'reject', 'manual_review', 'provider_error', 'pending')),
  -- Internal codes only. Never returned to users.
  moderation_categories  text[] not null default '{}',
  review_reasons         text[] not null default '{}',
  last_error_code        text check (char_length(last_error_code) <= 60),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index photo_processing_queue_idx
  on private.photo_processing (next_attempt_at)
  where stage in ('uploaded', 'processing_failed', 'awaiting_provider');
create index photo_processing_review_idx
  on private.photo_processing (updated_at)
  where stage = 'awaiting_manual_review';

create trigger photo_processing_touch_updated_at
  before update on private.photo_processing
  for each row execute function private.touch_updated_at();

create table private.photo_processing_events (
  id          bigint generated always as identity primary key,
  photo_id    uuid not null,
  owner_id    uuid not null,
  event_type  text not null check (event_type in (
    'upload_accepted', 'processing_started', 'validation_failed',
    'fingerprints_recorded', 'provider_check_requested', 'provider_check_completed',
    'manual_review_requested', 'approved', 'rejected', 'quarantined',
    'processing_failed', 'retry_scheduled', 'retry_requested', 'result_ignored',
    'verification_compare_accessed', 'upload_expired', 'deletion_queued',
    'deleted', 'deletion_skipped_hold', 'deletion_failed'
  )),
  actor_type  text not null check (actor_type in ('user', 'worker', 'moderator', 'system')),
  actor_id    uuid,
  attempt     integer,
  created_at  timestamptz not null default now(),
  -- Reason codes only: no image bytes, hashes, paths, URLs or provider payloads.
  details     jsonb not null default '{}'::jsonb check (pg_column_size(details) <= 1024)
);

create index photo_processing_events_photo_idx on private.photo_processing_events (photo_id, created_at);

create trigger photo_processing_events_append_only
  before update or delete on private.photo_processing_events
  for each row execute function private.forbid_modification();

create function private.log_photo_event(
  p_photo_id uuid,
  p_event_type text,
  p_actor_type text,
  p_actor_id uuid default null,
  p_attempt integer default null,
  p_details jsonb default '{}'::jsonb
)
returns void
language sql
set search_path = ''
as $$
  insert into private.photo_processing_events (photo_id, owner_id, event_type, actor_type, actor_id, attempt, details)
  select p_photo_id, m.owner_id, p_event_type, p_actor_type, p_actor_id, p_attempt, coalesce(p_details, '{}'::jsonb)
  from private.media_assets m where m.id = p_photo_id
$$;

-- New profile photos enter the pipeline automatically.
create function private.enqueue_photo_processing()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.photo_processing (photo_id) values (new.id)
  on conflict (photo_id) do nothing;
  perform private.log_photo_event(new.id, 'upload_accepted', 'user', new.user_id);
  return new;
end;
$$;

create trigger profile_photos_enqueue_processing
  after insert on private.profile_photos
  for each row execute function private.enqueue_photo_processing();

-- Existing photos: pending ones enter the queue; already-decided ones are
-- recorded as completed (they keep their current state).
insert into private.photo_processing (photo_id, stage, next_attempt_at)
select p.id,
       case when m.moderation_state = 'pending_scan' then 'uploaded' else 'completed' end,
       case when m.moderation_state = 'pending_scan' then now() else null end
from private.profile_photos p
join private.media_assets m on m.id = p.id
on conflict (photo_id) do nothing;

-- Full internal state, combining moderation state and pipeline stage.
create function private.photo_pipeline_state(p_photo_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p.removed_at is not null or m.moderation_state = 'removed' then 'removed'
    when m.moderation_state = 'awaiting_upload' then 'pending_upload'
    when m.moderation_state in ('approved', 'rejected', 'quarantined') then m.moderation_state
    else coalesce(pp.stage, 'uploaded')
  end
  from private.media_assets m
  left join private.profile_photos p on p.id = m.id
  left join private.photo_processing pp on pp.photo_id = m.id
  where m.id = p_photo_id
$$;

-- ---------------------------------------------------------------------------
-- Decision helpers (internal)
-- ---------------------------------------------------------------------------

create function private.photo_apply_rejection(p_photo_id uuid, p_actor_type text, p_actor_id uuid, p_attempt integer, p_reason text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  owner uuid;
begin
  update private.media_assets set moderation_state = 'rejected', decided_at = now()
  where id = p_photo_id and moderation_state in ('pending_scan', 'approved')
  returning owner_id into owner;
  update private.photo_processing
  set stage = 'completed', lease_expires_at = null, next_attempt_at = null
  where photo_id = p_photo_id;
  perform private.log_photo_event(p_photo_id, 'rejected', p_actor_type, p_actor_id, p_attempt,
    jsonb_build_object('reason', p_reason));
end;
$$;

create function private.photo_apply_approval(p_photo_id uuid, p_actor_type text, p_actor_id uuid, p_attempt integer)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update private.media_assets set moderation_state = 'approved', published_at = now(), decided_at = now()
  where id = p_photo_id and moderation_state = 'pending_scan';
  update private.photo_processing
  set stage = 'completed', lease_expires_at = null, next_attempt_at = null
  where photo_id = p_photo_id;
  perform private.log_photo_event(p_photo_id, 'approved', p_actor_type, p_actor_id, p_attempt);
end;
$$;

-- Fail closed: never approve; retry with exponential backoff until the
-- attempt limit, then wait for a moderator retry.
create function private.photo_apply_failure(p_photo_id uuid, p_error_code text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  pp private.photo_processing;
begin
  select * into pp from private.photo_processing where photo_id = p_photo_id;
  if pp.attempts >= cfg.photo_processing_max_attempts then
    update private.photo_processing
    set stage = 'processing_failed', lease_expires_at = null, next_attempt_at = null,
        last_error_code = left(p_error_code, 60)
    where photo_id = p_photo_id;
    perform private.log_photo_event(p_photo_id, 'processing_failed', 'system', null, pp.attempts,
      jsonb_build_object('error', left(p_error_code, 60), 'final', true));
    return 'processing_failed';
  end if;

  update private.photo_processing
  set stage = 'processing_failed', lease_expires_at = null,
      next_attempt_at = now() + make_interval(mins => power(2, pp.attempts)::integer),
      last_error_code = left(p_error_code, 60)
  where photo_id = p_photo_id;
  perform private.log_photo_event(p_photo_id, 'retry_scheduled', 'system', null, pp.attempts,
    jsonb_build_object('error', left(p_error_code, 60)));
  return 'retry_scheduled';
end;
$$;

-- Whether a photo can still be decided by the pipeline at all.
create function private.photo_is_processable(p_photo_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from private.media_assets m
    join private.profile_photos p on p.id = m.id
    where m.id = p_photo_id
      and m.purpose = 'profile_photo'
      and m.bucket_id = 'profile-photos'
      and m.moderation_state = 'pending_scan'
      and p.removed_at is null
      and p.user_id = m.owner_id
      and not private.has_active_safety_hold(m.owner_id)
      and not exists (select 1 from private.child_safety_cases c where c.media_asset_id = m.id)
      and exists (
        select 1 from storage.objects o
        where o.bucket_id = 'profile-photos'
          and o.name = m.object_path
          and o.owner_id = m.owner_id::text
      )
  )
$$;

-- ---------------------------------------------------------------------------
-- Worker API (service role only)
-- ---------------------------------------------------------------------------

-- Leases up to p_limit photos that are ready for (re)processing. Photos of
-- held accounts, removed photos and photos without a matching storage
-- object are never handed out. Expired leases are reclaimed.
create function public.pipeline_claim_photos(p_limit integer default 10, p_worker text default null)
returns table (photo_id uuid, owner_id uuid, bucket_id text, object_path text, attempt integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  claimed record;
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;

  for claimed in
    select pp.photo_id
    from private.photo_processing pp
    where pp.attempts < cfg.photo_processing_max_attempts
      and (
        (pp.stage in ('uploaded', 'processing_failed', 'awaiting_provider') and pp.next_attempt_at <= now())
        or (pp.stage = 'processing' and pp.lease_expires_at < now())
      )
      and private.photo_is_processable(pp.photo_id)
    order by pp.next_attempt_at nulls last
    limit least(greatest(p_limit, 1), 50)
    for update of pp skip locked
  loop
    update private.photo_processing
    set stage = 'processing',
        attempts = attempts + 1,
        lease_expires_at = now() + cfg.photo_processing_lease,
        worker_id = left(p_worker, 100)
    where private.photo_processing.photo_id = claimed.photo_id;

    perform private.log_photo_event(claimed.photo_id, 'processing_started', 'worker', null,
      (select attempts from private.photo_processing where private.photo_processing.photo_id = claimed.photo_id));

    return query
      select m.id, m.owner_id, m.bucket_id, m.object_path, pp.attempts
      from private.media_assets m
      join private.photo_processing pp on pp.photo_id = m.id
      where m.id = claimed.photo_id;
  end loop;
end;
$$;

-- Accepts the worker's findings for one attempt and decides the outcome.
--
-- p_result shape (all keys optional; missing checks fail closed):
-- {
--   "validation":   {"ok": true, "error": null, "width": 1200, "height": 1600, "bytes": 234567},
--   "fingerprints": {"sha256": "<64 hex>", "perceptual_hash": "<64 bits as 0/1>"},
--   "child_safety": {"result": "clear|possible_match|confirmed_known_hash_match|provider_error|manual_review_required|pending"},
--   "moderation":   {"result": "approve|reject|manual_review|provider_error|pending", "categories": ["..."]}
-- }
--
-- Idempotent: a result for anything but the current attempt of a photo
-- that is still being processed is ignored ("stale").
create function public.pipeline_submit_result(p_photo_id uuid, p_attempt integer, p_result jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  pp private.photo_processing;
  asset private.media_assets;
  obj_size bigint;
  obj_mime text;
  bucket_limit bigint;
  v jsonb := coalesce(p_result -> 'validation', '{}'::jsonb);
  fp jsonb := coalesce(p_result -> 'fingerprints', '{}'::jsonb);
  cs text := p_result -> 'child_safety' ->> 'result';
  mod text := p_result -> 'moderation' ->> 'result';
  categories text[];
  width integer;
  height integer;
  bytes integer;
  v_error text;
  sha text := fp ->> 'sha256';
  phash text := fp ->> 'perceptual_hash';
  exact_dup boolean;
  near_dup boolean;
  reasons text[] := '{}';
  case_category text;
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;

  -- Unknown provider values are treated as missing (fail closed), never
  -- as errors or approvals.
  if cs not in ('clear', 'possible_match', 'confirmed_known_hash_match', 'provider_error',
                'manual_review_required', 'pending') then
    cs := 'manual_review_required';
  end if;
  if mod not in ('approve', 'reject', 'manual_review', 'provider_error', 'pending') then
    mod := 'manual_review';
  end if;

  select * into pp from private.photo_processing where photo_id = p_photo_id for update;
  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;
  if pp.stage <> 'processing' or pp.attempts <> p_attempt then
    perform private.log_photo_event(p_photo_id, 'result_ignored', 'worker', null, p_attempt,
      jsonb_build_object('reason', 'stale'));
    return jsonb_build_object('outcome', 'stale', 'stage', private.photo_pipeline_state(p_photo_id));
  end if;

  select * into asset from private.media_assets where id = p_photo_id for update;
  if not private.photo_is_processable(p_photo_id) then
    -- Removed, held, quarantined or object gone since the claim.
    update private.photo_processing
    set stage = case when asset.moderation_state = 'pending_scan' then 'awaiting_manual_review' else 'completed' end,
        lease_expires_at = null, next_attempt_at = null
    where photo_id = p_photo_id;
    perform private.log_photo_event(p_photo_id, 'result_ignored', 'worker', null, p_attempt,
      jsonb_build_object('reason', 'not_processable'));
    return jsonb_build_object('outcome', 'not_processable', 'stage', private.photo_pipeline_state(p_photo_id));
  end if;

  -- ------------------------------------------------ validation
  -- The worker's findings are cross-checked against Storage's own record
  -- of the (normalised) object; a client-declared MIME type is not trusted.
  select (o.metadata ->> 'size')::bigint, o.metadata ->> 'mimetype'
    into obj_size, obj_mime
  from storage.objects o
  where o.bucket_id = 'profile-photos' and o.name = asset.object_path;
  select file_size_limit into bucket_limit from storage.buckets where id = 'profile-photos';

  width := (v ->> 'width')::integer;
  height := (v ->> 'height')::integer;
  bytes := (v ->> 'bytes')::integer;

  v_error := case
    when coalesce((v ->> 'ok')::boolean, false) = false then coalesce(v ->> 'error', 'malformed')
    when bytes is null or bytes <= 0 then 'empty'
    when bucket_limit is not null and bytes > bucket_limit then 'too_large'
    when obj_size is not null and obj_size <> bytes then 'size_mismatch'
    when obj_mime is not null and obj_mime <> 'image/jpeg' then 'not_jpeg'
    when width is null or height is null then 'undecodable'
    when least(width, height) < cfg.min_photo_dimension then 'too_small'
    when greatest(width, height) > cfg.max_photo_dimension then 'dimensions_too_large'
    else null
  end;
  if v_error is not null and v_error not in (
    'empty', 'too_large', 'not_jpeg', 'malformed', 'undecodable', 'too_small',
    'dimensions_too_large', 'size_mismatch', 'wrong_path', 'missing_object') then
    v_error := 'malformed';
  end if;

  update private.photo_processing
  set image_width = width, image_height = height, byte_size = bytes,
      validation_error = v_error,
      validated_at = case when v_error is null then now() else null end
  where photo_id = p_photo_id;

  if v_error is not null then
    perform private.log_photo_event(p_photo_id, 'validation_failed', 'worker', null, p_attempt,
      jsonb_build_object('error', v_error));
    perform private.photo_apply_rejection(p_photo_id, 'system', null, p_attempt, 'invalid_file');
    return jsonb_build_object('outcome', 'rejected', 'stage', 'rejected');
  end if;

  -- ------------------------------------------------ fingerprints
  -- coalesce: a missing value must fail the check, not skip it.
  if coalesce(sha, '') !~ '^[0-9a-f]{64}$' or coalesce(phash, '') !~ '^[01]{64}$' then
    return jsonb_build_object('outcome', private.photo_apply_failure(p_photo_id, 'missing_fingerprints'),
                              'stage', 'processing_failed');
  end if;

  if asset.sha256 is null then
    select exists (
             select 1 from private.media_assets o
             where o.purpose = 'profile_photo' and o.owner_id <> asset.owner_id
               and o.sha256 = sha and o.moderation_state in ('approved', 'pending_scan')),
           exists (
             select 1 from private.media_assets o
             where o.purpose = 'profile_photo' and o.owner_id <> asset.owner_id
               and o.perceptual_hash is not null
               and o.moderation_state in ('approved', 'pending_scan')
               and bit_count(o.perceptual_hash # phash::bit(64)) <= cfg.near_duplicate_image_distance)
      into exact_dup, near_dup;
    -- Records reuse signals once; later retries skip this branch.
    perform private.register_media_hashes(p_photo_id, sha, phash::bit(64));
    perform private.log_photo_event(p_photo_id, 'fingerprints_recorded', 'worker', null, p_attempt,
      jsonb_build_object('exact_duplicate', exact_dup, 'near_duplicate', near_dup and not exact_dup));
    if exact_dup then
      reasons := reasons || 'duplicate_exact'::text;
    elsif near_dup then
      reasons := reasons || 'duplicate_near'::text;
    end if;
    -- Saved now: fingerprinting happens once, so a retry after a later
    -- failure must still see the duplicate.
    update private.photo_processing set review_reasons = reasons where photo_id = p_photo_id;
  elsif asset.sha256 <> sha or asset.perceptual_hash <> phash::bit(64) then
    -- The same normalised image must produce the same fingerprints.
    return jsonb_build_object('outcome', private.photo_apply_failure(p_photo_id, 'fingerprint_mismatch'),
                              'stage', 'processing_failed');
  else
    reasons := reasons || array(select r from unnest(pp.review_reasons) as t(r) where r like 'duplicate_%');
  end if;

  -- ------------------------------------------------ child safety
  perform private.log_photo_event(p_photo_id, 'provider_check_completed', 'worker', null, p_attempt,
    jsonb_build_object('check', 'child_safety', 'result', coalesce(cs, 'missing')));
  update private.photo_processing set child_safety_result = cs where photo_id = p_photo_id;

  if cs in ('confirmed_known_hash_match', 'possible_match') then
    case_category := case cs when 'confirmed_known_hash_match' then 'known_csam_hash_match' else 'suspected_csam' end;
    if not exists (select 1 from private.child_safety_cases where media_asset_id = p_photo_id) then
      perform private.open_child_safety_case(
        asset.owner_id, case_category,
        case cs when 'confirmed_known_hash_match' then 'hash_match_provider' else 'classifier_provider' end,
        null, p_photo_id, true);
    end if;
    update private.photo_processing
    set stage = 'completed', lease_expires_at = null, next_attempt_at = null
    where photo_id = p_photo_id;
    perform private.log_photo_event(p_photo_id, 'quarantined', 'system', null, p_attempt);
    return jsonb_build_object('outcome', 'quarantined', 'stage', 'quarantined');
  elsif cs = 'provider_error' or cs is null and p_result ? 'child_safety' then
    return jsonb_build_object('outcome', private.photo_apply_failure(p_photo_id, 'child_safety_provider_error'),
                              'stage', 'processing_failed');
  elsif cs = 'pending' then
    update private.photo_processing
    set stage = 'awaiting_provider', lease_expires_at = null, next_attempt_at = now() + interval '2 minutes'
    where photo_id = p_photo_id;
    perform private.log_photo_event(p_photo_id, 'provider_check_requested', 'worker', null, p_attempt,
      jsonb_build_object('check', 'child_safety'));
    return jsonb_build_object('outcome', 'awaiting_provider', 'stage', 'awaiting_provider');
  elsif cs is distinct from 'clear' then
    -- manual_review_required, or no provider configured: fail closed.
    reasons := reasons || case when cs is null then 'child_safety_unavailable' else 'child_safety_manual' end;
  end if;

  -- ------------------------------------------------ general moderation
  categories := coalesce(
    array(select jsonb_array_elements_text(coalesce(p_result -> 'moderation' -> 'categories', '[]'::jsonb))),
    '{}');
  categories := array(select left(c, 40) from unnest(categories) c limit 10);
  update private.photo_processing
  set moderation_result = mod, moderation_categories = categories
  where photo_id = p_photo_id;

  if mod = 'reject' then
    perform private.record_abuse_signal(asset.owner_id, 'rejected_profile_photo', 'low',
      jsonb_build_object('categories', to_jsonb(categories)), null, 'media_scan');
    perform private.photo_apply_rejection(p_photo_id, 'system', null, p_attempt, 'content_policy');
    return jsonb_build_object('outcome', 'rejected', 'stage', 'rejected');
  elsif mod = 'provider_error' then
    return jsonb_build_object('outcome', private.photo_apply_failure(p_photo_id, 'moderation_provider_error'),
                              'stage', 'processing_failed');
  elsif mod = 'pending' then
    update private.photo_processing
    set stage = 'awaiting_provider', lease_expires_at = null, next_attempt_at = now() + interval '2 minutes'
    where photo_id = p_photo_id;
    return jsonb_build_object('outcome', 'awaiting_provider', 'stage', 'awaiting_provider');
  elsif mod is distinct from 'approve' then
    reasons := reasons || case when mod is null then 'moderation_unavailable' else 'moderation_manual' end;
  end if;

  -- ------------------------------------------------ decision
  if cardinality(reasons) > 0 or private.has_active_safety_hold(asset.owner_id) then
    update private.photo_processing
    set stage = 'awaiting_manual_review', review_reasons = reasons,
        lease_expires_at = null, next_attempt_at = null
    where photo_id = p_photo_id;
    perform private.log_photo_event(p_photo_id, 'manual_review_requested', 'system', null, p_attempt,
      jsonb_build_object('reasons', to_jsonb(reasons)));
    return jsonb_build_object('outcome', 'manual_review', 'stage', 'awaiting_manual_review');
  end if;

  perform private.photo_apply_approval(p_photo_id, 'system', null, p_attempt);
  return jsonb_build_object('outcome', 'approved', 'stage', 'approved');
end;
$$;

-- The worker couldn't finish (timeout, crash, download error). Same
-- idempotency rule as submitting a result.
create function public.pipeline_report_failure(p_photo_id uuid, p_attempt integer, p_error_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  pp private.photo_processing;
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  select * into pp from private.photo_processing where photo_id = p_photo_id for update;
  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;
  if pp.stage <> 'processing' or pp.attempts <> p_attempt then
    return jsonb_build_object('outcome', 'stale');
  end if;
  return jsonb_build_object('outcome', private.photo_apply_failure(p_photo_id, coalesce(p_error_code, 'unknown')));
end;
$$;

-- ---------------------------------------------------------------------------
-- Moderator functions (moderator role + MFA)
-- ---------------------------------------------------------------------------

-- Photos waiting for a human, oldest first. Child-safety cases are not
-- listed here; they belong to child-safety reviewers.
create function public.moderator_photos_awaiting_review(p_limit integer default 50)
returns table (
  photo_id uuid,
  owner_id uuid,
  uploaded_at timestamptz,
  review_reasons text[],
  moderation_categories text[],
  stage text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  return query
    select m.id, m.owner_id, m.created_at, pp.review_reasons, pp.moderation_categories, pp.stage
    from private.photo_processing pp
    join private.media_assets m on m.id = pp.photo_id
    join private.profile_photos p on p.id = m.id
    where pp.stage in ('awaiting_manual_review', 'processing_failed')
      and m.moderation_state = 'pending_scan'
      and p.removed_at is null
      and m.owner_id <> auth.uid()
      and not exists (select 1 from private.child_safety_cases c where c.media_asset_id = m.id)
    order by m.created_at
    limit least(greatest(p_limit, 1), 200);
end;
$$;

-- Approve / reject / remove. Replaces the version from the profile photos
-- migration: approval now also requires a successful pipeline validation
-- and a child-safety result that permits it.
create or replace function public.moderate_profile_photo(p_photo_id uuid, p_decision text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_type text;
  asset private.media_assets;
  pp private.photo_processing;
begin
  if private.is_moderator() then
    actor_type := 'moderator';
  elsif private.is_service_role() then
    actor_type := 'system';
  else
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_decision not in ('approve', 'reject', 'remove') then
    raise exception 'invalid decision' using errcode = 'check_violation';
  end if;

  select * into asset from private.media_assets where id = p_photo_id for update;
  if not found or not exists (select 1 from private.profile_photos where id = p_photo_id) then
    raise exception 'photo not found';
  end if;
  if actor_type = 'moderator' and asset.owner_id = auth.uid() then
    raise exception 'moderators cannot moderate their own photos' using errcode = 'insufficient_privilege';
  end if;
  if asset.moderation_state in ('quarantined', 'removed', 'awaiting_upload') then
    raise exception 'photo is not available for moderation';
  end if;
  select * into pp from private.photo_processing where photo_id = p_photo_id for update;

  if p_decision = 'approve' then
    if pp.validated_at is null then
      raise exception 'photo has not passed processing' using errcode = 'check_violation';
    end if;
    if pp.child_safety_result in ('possible_match', 'confirmed_known_hash_match')
       or exists (select 1 from private.child_safety_cases where media_asset_id = p_photo_id)
       or private.has_active_safety_hold(asset.owner_id) then
      raise exception 'photo is under child-safety review' using errcode = 'check_violation';
    end if;
    if asset.moderation_state <> 'pending_scan' then
      raise exception 'photo is not awaiting a decision' using errcode = 'check_violation';
    end if;
    perform private.photo_apply_approval(p_photo_id, case actor_type when 'moderator' then 'moderator' else 'system' end,
      case actor_type when 'moderator' then auth.uid() end, pp.attempts);
  elsif p_decision = 'reject' then
    perform private.photo_apply_rejection(p_photo_id, case actor_type when 'moderator' then 'moderator' else 'system' end,
      case actor_type when 'moderator' then auth.uid() end, pp.attempts, 'moderator_decision');
  else
    update private.media_assets set moderation_state = 'removed' where id = p_photo_id;
    update private.profile_photos
    set removed_at = now(), removed_by = case actor_type when 'moderator' then 'moderator' else 'system' end,
        removal_reason = left(p_reason, 200), is_primary = false
    where id = p_photo_id;
    update private.profile_photos set is_primary = true
    where id = (select id from private.profile_photos
                where user_id = asset.owner_id and removed_at is null
                order by position limit 1)
      and not exists (select 1 from private.profile_photos
                      where user_id = asset.owner_id and removed_at is null and is_primary);
    update private.photo_processing
    set stage = 'completed', lease_expires_at = null, next_attempt_at = null
    where photo_id = p_photo_id;
    insert into private.media_deletion_queue (bucket_id, object_path, media_asset_id)
    select asset.bucket_id, asset.object_path, asset.id
    where not exists (select 1 from private.media_deletion_queue q
                      where q.bucket_id = asset.bucket_id and q.object_path = asset.object_path);
  end if;

  if actor_type = 'moderator' then
    insert into private.moderation_actions (target_user_id, action, reason, moderator_id)
    values (asset.owner_id, 'photo_' || p_decision, left(p_reason, 500), auth.uid());
  end if;
end;
$$;

-- Lets a moderator restart processing of a failed photo.
create function public.moderator_retry_photo_processing(p_photo_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  update private.photo_processing
  set stage = 'uploaded', attempts = 0, next_attempt_at = now(), lease_expires_at = null, last_error_code = null
  where photo_id = p_photo_id and stage = 'processing_failed';
  if not found then
    raise exception 'photo is not in a failed state';
  end if;
  perform private.log_photo_event(p_photo_id, 'retry_requested', 'moderator', auth.uid());
end;
$$;

-- For a future moderator tool: locations of a pending/approved profile
-- photo and the owner's most recent approved verification photo, so a
-- backend can issue short-lived signed URLs for side-by-side comparison by
-- eye. No face matching. Refused for anything under child-safety review
-- (those need a child-safety reviewer). Every call is audited.
create function public.moderator_photo_review_context(p_photo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  asset private.media_assets;
  verification_path text;
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  select * into asset from private.media_assets where id = p_photo_id and purpose = 'profile_photo';
  if not found then
    raise exception 'photo not found';
  end if;
  if asset.owner_id = auth.uid() then
    raise exception 'moderators cannot review their own photos' using errcode = 'insufficient_privilege';
  end if;
  if asset.moderation_state = 'quarantined'
     or exists (select 1 from private.child_safety_cases where media_asset_id = p_photo_id)
     or private.has_active_safety_hold(asset.owner_id) then
    raise exception 'restricted to child-safety reviewers' using errcode = 'insufficient_privilege';
  end if;

  select s.media_object_path into verification_path
  from private.verification_sessions s
  where s.user_id = asset.owner_id and s.status = 'approved'
    and s.media_object_path is not null and s.media_deleted_at is null
  order by s.reviewed_at desc
  limit 1;

  perform private.log_photo_event(p_photo_id, 'verification_compare_accessed', 'moderator', auth.uid());

  return jsonb_build_object(
    'profile_photo', jsonb_build_object('bucket_id', asset.bucket_id, 'object_path', asset.object_path),
    'verification_photo', case when verification_path is null then null
      else jsonb_build_object('bucket_id', 'verification-media', 'object_path', verification_path) end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Storage clean-up
-- ---------------------------------------------------------------------------

alter table private.media_deletion_queue
  add column media_asset_id uuid,
  add column verification_session_id uuid,
  add column status text not null default 'pending'
    check (status in ('pending', 'claimed', 'deleted', 'skipped_hold', 'failed')),
  add column attempts integer not null default 0,
  add column claimed_until timestamptz,
  add column last_error text check (char_length(last_error) <= 60),
  add column processed_at timestamptz;

update private.media_deletion_queue set status = 'deleted' where deleted_at is not null;

create index media_deletion_queue_work_idx
  on private.media_deletion_queue (queued_at) where status in ('pending', 'claimed', 'failed');

-- Why an object must NOT be deleted, or null if deletion is safe.
create function private.deletion_hold_reason(p_bucket_id text, p_object_path text)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_bucket_id = 'child-safety-evidence' then 'evidence_bucket'
    when exists (
      select 1 from private.media_assets m
      where m.bucket_id = p_bucket_id and m.object_path = p_object_path
        and (m.moderation_state = 'quarantined'
             or exists (select 1 from private.media_quarantine q where q.media_asset_id = m.id and q.released_at is null)
             or exists (select 1 from private.child_safety_cases c where c.media_asset_id = m.id
                        and (c.legal_hold or c.status not in ('closed_no_violation', 'closed_actioned')))
             or private.has_active_safety_hold(m.owner_id))
    ) then 'safety_hold'
    else null
  end
$$;

-- Adds files that are due for deletion: rejected photos past retention,
-- abandoned upload slots, and verification media past its retention.
create function public.cleanup_enqueue_expired()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  added integer := 0;
  n integer;
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;

  -- Abandoned upload slots.
  with expired as (
    update private.media_assets m set moderation_state = 'removed'
    where m.bucket_id = 'profile-photos' and m.moderation_state = 'awaiting_upload'
      and m.created_at < now() - cfg.profile_photo_upload_window
    returning m.id, m.bucket_id, m.object_path
  ), queued as (
    insert into private.media_deletion_queue (bucket_id, object_path, media_asset_id)
    select e.bucket_id, e.object_path, e.id from expired e
    where not exists (select 1 from private.media_deletion_queue q
                      where q.bucket_id = e.bucket_id and q.object_path = e.object_path)
    returning 1
  )
  select count(*) into n from queued;
  added := added + n;

  -- Rejected photos past retention, never anything with a safety link.
  with due as (
    select m.id, m.bucket_id, m.object_path from private.media_assets m
    where m.bucket_id = 'profile-photos' and m.moderation_state = 'rejected'
      and coalesce(m.decided_at, m.updated_at) < now() - cfg.rejected_photo_retention
      and private.deletion_hold_reason(m.bucket_id, m.object_path) is null
      and not exists (select 1 from private.media_deletion_queue q
                      where q.bucket_id = m.bucket_id and q.object_path = m.object_path)
  ), queued as (
    insert into private.media_deletion_queue (bucket_id, object_path, media_asset_id)
    select bucket_id, object_path, id from due
    returning 1
  )
  select count(*) into n from queued;
  added := added + n;

  -- Verification media past retention (uses the verification migration's
  -- retention rules).
  with due as (
    select d.session_id, d.object_path from private.verification_media_due_for_deletion(500) d
    where not exists (select 1 from private.media_deletion_queue q
                      where q.bucket_id = 'verification-media' and q.object_path = d.object_path)
  ), queued as (
    insert into private.media_deletion_queue (bucket_id, object_path, verification_session_id)
    select 'verification-media', object_path, session_id from due
    returning 1
  )
  select count(*) into n from queued;
  added := added + n;

  return added;
end;
$$;

-- Leases queue items for deletion. Anything under a hold is marked
-- skipped instead and never returned.
create function public.cleanup_claim_deletions(p_limit integer default 50)
returns table (queue_id bigint, bucket_id text, object_path text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  cfg private.security_settings := private.settings();
  item record;
  hold text;
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;

  for item in
    select q.id, q.bucket_id, q.object_path, q.media_asset_id
    from private.media_deletion_queue q
    where (q.status in ('pending', 'failed') or (q.status = 'claimed' and q.claimed_until < now()))
      and q.attempts < cfg.deletion_max_attempts
    order by q.queued_at
    limit least(greatest(p_limit, 1), 200)
    for update of q skip locked
  loop
    hold := private.deletion_hold_reason(item.bucket_id, item.object_path);
    if hold is not null then
      update private.media_deletion_queue
      set status = 'skipped_hold', processed_at = now(), last_error = hold
      where id = item.id;
      if item.media_asset_id is not null then
        perform private.log_photo_event(item.media_asset_id, 'deletion_skipped_hold', 'system');
      end if;
      continue;
    end if;

    update private.media_deletion_queue
    set status = 'claimed', claimed_until = now() + interval '10 minutes', attempts = attempts + 1
    where id = item.id;
    queue_id := item.id;
    bucket_id := item.bucket_id;
    object_path := item.object_path;
    return next;
  end loop;
end;
$$;

-- Records the outcome of one deletion. Re-checks holds, so a hold applied
-- after the claim still wins (the worker must only delete after this
-- returns 'confirmed' for a pre-check, see the Edge Function).
create function public.cleanup_mark_result(p_queue_id bigint, p_success boolean, p_error text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  item private.media_deletion_queue;
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  select * into item from private.media_deletion_queue where id = p_queue_id for update;
  if not found or item.status in ('deleted', 'skipped_hold') then
    return 'ignored';
  end if;

  if p_success then
    update private.media_deletion_queue
    set status = 'deleted', deleted_at = now(), processed_at = now(), claimed_until = null
    where id = p_queue_id;
    if item.media_asset_id is not null then
      perform private.log_photo_event(item.media_asset_id, 'deleted', 'system');
    end if;
    if item.verification_session_id is not null then
      perform private.mark_verification_media_deleted(item.verification_session_id);
    end if;
    return 'deleted';
  end if;

  update private.media_deletion_queue
  set status = 'failed', last_error = left(coalesce(p_error, 'unknown'), 60), claimed_until = null
  where id = p_queue_id;
  if item.media_asset_id is not null then
    perform private.log_photo_event(item.media_asset_id, 'deletion_failed', 'system', null, null,
      jsonb_build_object('error', left(coalesce(p_error, 'unknown'), 60)));
  end if;
  return 'failed';
end;
$$;

-- Final check right before the worker deletes a claimed object.
create function public.cleanup_confirm_deletable(p_queue_id bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  item private.media_deletion_queue;
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  select * into item from private.media_deletion_queue where id = p_queue_id for update;
  if not found or item.status <> 'claimed' then
    return false;
  end if;
  if private.deletion_hold_reason(item.bucket_id, item.object_path) is not null then
    update private.media_deletion_queue
    set status = 'skipped_hold', processed_at = now(), last_error = 'safety_hold', claimed_until = null
    where id = p_queue_id;
    return false;
  end if;
  return true;
end;
$$;

-- Keep the queue link for photo deletions made by users.
create or replace function public.delete_profile_photo(p_photo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  photo private.profile_photos;
  asset private.media_assets;
  next_primary uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into photo from private.profile_photos
  where id = p_photo_id and user_id = uid and removed_at is null
  for update;
  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;
  select * into asset from private.media_assets where id = photo.id;
  if asset.moderation_state = 'quarantined'
     or private.has_active_safety_hold(uid)
     or exists (select 1 from private.child_safety_cases where media_asset_id = photo.id) then
    return jsonb_build_object('outcome', 'under_review');
  end if;

  update private.profile_photos
  set removed_at = now(), removed_by = 'user', is_primary = false
  where id = photo.id;
  update private.media_assets set moderation_state = 'removed' where id = photo.id;
  update private.photo_processing
  set stage = 'completed', lease_expires_at = null, next_attempt_at = null
  where photo_id = photo.id;
  insert into private.media_deletion_queue (bucket_id, object_path, media_asset_id)
  select asset.bucket_id, asset.object_path, asset.id
  where not exists (select 1 from private.media_deletion_queue q
                    where q.bucket_id = asset.bucket_id and q.object_path = asset.object_path);
  perform private.log_photo_event(photo.id, 'deletion_queued', 'user', uid);

  with ordered as (
    select id, row_number() over (order by position) as new_position
    from private.profile_photos where user_id = uid and removed_at is null
  )
  update private.profile_photos p set position = o.new_position
  from ordered o where p.id = o.id and p.position <> o.new_position;

  if photo.is_primary then
    select id into next_primary from private.profile_photos
    where user_id = uid and removed_at is null order by position limit 1;
    if next_primary is not null then
      update private.profile_photos set is_primary = true where id = next_primary;
    end if;
  end if;

  return jsonb_build_object('outcome', 'removed');
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke all on all tables in schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_write_verification_object(text) to authenticated;
grant execute on function private.owns_verification_object(text) to authenticated;
grant execute on function private.can_upload_profile_photo_object(text) to authenticated;
grant execute on function private.can_read_profile_photo_object(text) to authenticated;

do $$
declare
  fn text;
begin
  -- Worker API: service role only.
  foreach fn in array array[
    'public.pipeline_claim_photos(integer, text)',
    'public.pipeline_submit_result(uuid, integer, jsonb)',
    'public.pipeline_report_failure(uuid, integer, text)',
    'public.cleanup_enqueue_expired()',
    'public.cleanup_claim_deletions(integer)',
    'public.cleanup_mark_result(bigint, boolean, text)',
    'public.cleanup_confirm_deletable(bigint)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', fn);
    execute format('grant execute on function %s to service_role', fn);
  end loop;

  -- Moderator API: signed-in callers, checked for role + MFA inside.
  foreach fn in array array[
    'public.moderator_photos_awaiting_review(integer)',
    'public.moderator_retry_photo_processing(uuid)',
    'public.moderator_photo_review_context(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;

revoke execute on function public.moderate_profile_photo(uuid, text, text) from public, anon;
grant execute on function public.moderate_profile_photo(uuid, text, text) to authenticated, service_role;
revoke execute on function public.delete_profile_photo(uuid) from public, anon;
grant execute on function public.delete_profile_photo(uuid) to authenticated;
