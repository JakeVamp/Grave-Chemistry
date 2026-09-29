-- Grave Chemistry: moderator photo-review tool
--
-- Backend for the in-app moderator review tool. Builds on the functions
-- from the photo-processing pipeline; adds:
--   * a review queue with only what a moderator needs to decide (no hashes,
--     provider payloads, storage paths or child-safety data)
--   * private, append-only moderator notes
--   * one audit trail for every moderator photo action
--     (private.moderation_actions, now linked to the photo)
--   * stricter moderator approval: only photos waiting for manual review,
--     so an item changed by another moderator can't be approved
--   * exclusion of held accounts from the normal queue (a safety hold means
--     child-safety review is in progress)
--
-- Signed URLs for side-by-side review are issued by the
-- `moderator-review-media` Edge Function, only after
-- moderator_photo_review_context() has re-checked role + MFA.

-- ---------------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------------

alter table private.moderation_actions
  add column media_asset_id uuid,
  drop constraint moderation_actions_action_check,
  add constraint moderation_actions_action_check check (action in (
    'dismiss', 'warn', 'restrict', 'suspend', 'ban', 'require_reverification',
    'lift_restriction', 'clear_review', 'photo_approve', 'photo_reject', 'photo_remove',
    'photo_review_opened', 'photo_retry', 'photo_escalate_child_safety', 'photo_note_added'
  ));

create index moderation_actions_media_idx
  on private.moderation_actions (media_asset_id, created_at desc)
  where media_asset_id is not null;

alter table private.photo_processing_events
  drop constraint photo_processing_events_event_type_check,
  add constraint photo_processing_events_event_type_check check (event_type in (
    'upload_accepted', 'processing_started', 'validation_failed',
    'fingerprints_recorded', 'provider_check_requested', 'provider_check_completed',
    'manual_review_requested', 'approved', 'rejected', 'quarantined',
    'processing_failed', 'retry_scheduled', 'retry_requested', 'result_ignored',
    'verification_compare_accessed', 'upload_expired', 'deletion_queued',
    'deleted', 'deletion_skipped_hold', 'deletion_failed', 'removed'
  ));

-- Records a moderator action. Reason text is truncated; never pass image
-- data, URLs, paths or child-safety details.
create function private.log_moderator_action(
  p_target_user_id uuid,
  p_action text,
  p_media_asset_id uuid default null,
  p_reason text default null
)
returns void
language sql
set search_path = ''
as $$
  insert into private.moderation_actions (target_user_id, action, reason, moderator_id, media_asset_id)
  values (p_target_user_id, p_action, left(p_reason, 500), auth.uid(), p_media_asset_id)
$$;

-- ---------------------------------------------------------------------------
-- Reviewability
-- ---------------------------------------------------------------------------

-- Whether an ordinary moderator may see this photo at all: not their own,
-- not quarantined, no child-safety case, and the owner has no safety hold.
-- Child-safety matters belong to child-safety reviewers only.
create function private.moderator_can_see_photo(p_photo_id uuid)
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
      and m.owner_id is distinct from auth.uid()
      and m.moderation_state <> 'quarantined'
      and not exists (select 1 from private.child_safety_cases c where c.media_asset_id = m.id)
      and not private.has_active_safety_hold(m.owner_id)
  )
$$;

-- ---------------------------------------------------------------------------
-- Queue
-- ---------------------------------------------------------------------------

-- Same criteria as before, and now also excludes held accounts.
create or replace function public.moderator_photos_awaiting_review(p_limit integer default 50)
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
      and private.moderator_can_see_photo(m.id)
    order by m.created_at
    limit least(greatest(p_limit, 1), 200);
end;
$$;

-- One review row. Internal reason codes are reduced to review-useful flags.
create function private.moderator_review_row(p_photo_id uuid)
returns table (
  photo_id uuid,
  owner_id uuid,
  uploaded_at timestamptz,
  display_name text,
  age integer,
  verification_status text,
  has_review_signals boolean,
  duplicate_match text,
  content_flagged boolean,
  automated_checks_incomplete boolean,
  review_state text,
  can_approve boolean,
  can_retry boolean
)
language sql
stable
set search_path = ''
as $$
  select
    m.id,
    m.owner_id,
    m.created_at,
    pr.display_name,
    case when pr.birth_date is null then null
         else date_part('year', age(current_date, pr.birth_date))::integer end,
    coalesce(pr.verification_status, 'not_started'),
    coalesce(a.manual_review_required, false)
      or exists (select 1 from private.abuse_signals s
                 where s.user_id = m.owner_id and s.review_status = 'open'),
    case when 'duplicate_exact' = any(pp.review_reasons) then 'exact'
         when 'duplicate_near' = any(pp.review_reasons) then 'similar' end,
    'moderation_manual' = any(pp.review_reasons),
    pp.review_reasons && array['child_safety_unavailable', 'child_safety_manual', 'moderation_unavailable'],
    case
      when p.removed_at is not null or m.moderation_state in ('removed', 'rejected', 'approved') then 'decided'
      when pp.stage = 'awaiting_manual_review' then 'awaiting_review'
      when pp.stage = 'processing_failed' and pp.next_attempt_at is null then 'processing_failed'
      else 'processing'
    end,
    m.moderation_state = 'pending_scan' and p.removed_at is null
      and pp.stage = 'awaiting_manual_review' and pp.validated_at is not null,
    m.moderation_state = 'pending_scan' and p.removed_at is null
      and pp.stage = 'processing_failed'
  from private.media_assets m
  join private.profile_photos p on p.id = m.id
  join private.photo_processing pp on pp.photo_id = m.id
  left join public.profiles pr on pr.id = m.owner_id
  left join private.accounts a on a.user_id = m.owner_id
  where m.id = p_photo_id
    and private.moderator_can_see_photo(m.id)
$$;

-- The moderator review queue: photos waiting for a human or whose
-- processing failed, oldest first.
create function public.moderator_photo_review_queue(p_limit integer default 50)
returns table (
  photo_id uuid,
  owner_id uuid,
  uploaded_at timestamptz,
  display_name text,
  age integer,
  verification_status text,
  has_review_signals boolean,
  duplicate_match text,
  content_flagged boolean,
  automated_checks_incomplete boolean,
  review_state text,
  can_approve boolean,
  can_retry boolean
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
    select r.*
    from public.moderator_photos_awaiting_review(p_limit) q
    cross join lateral private.moderator_review_row(q.photo_id) r
    order by r.uploaded_at;
end;
$$;

-- Current state of one item, e.g. after another moderator acted on it.
-- Returns no row when the photo is gone or restricted to child safety
-- (indistinguishable on purpose).
create function public.moderator_photo_review_item(p_photo_id uuid)
returns table (
  photo_id uuid,
  owner_id uuid,
  uploaded_at timestamptz,
  display_name text,
  age integer,
  verification_status text,
  has_review_signals boolean,
  duplicate_match text,
  content_flagged boolean,
  automated_checks_incomplete boolean,
  review_state text,
  can_approve boolean,
  can_retry boolean
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
  return query select * from private.moderator_review_row(p_photo_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Moderator notes (private, append-only)
-- ---------------------------------------------------------------------------
-- Never visible to users and never returned by user-facing functions.
-- Notes are for review context only: no provider secrets, URLs or
-- child-safety evidence (child-safety matters go to reviewers instead).

create table private.moderator_notes (
  id              bigint generated always as identity primary key,
  media_asset_id  uuid not null,
  target_user_id  uuid not null,
  moderator_id    uuid not null,
  body            text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at      timestamptz not null default now()
);

create index moderator_notes_media_idx on private.moderator_notes (media_asset_id, created_at);

create trigger moderator_notes_append_only
  before update or delete on private.moderator_notes
  for each row execute function private.forbid_modification();

create function public.moderator_add_photo_note(p_photo_id uuid, p_body text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid;
  note_id bigint;
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if not private.moderator_can_see_photo(p_photo_id) then
    raise exception 'photo not available';
  end if;
  select owner_id into owner from private.media_assets where id = p_photo_id;
  insert into private.moderator_notes (media_asset_id, target_user_id, moderator_id, body)
  values (p_photo_id, owner, auth.uid(), btrim(p_body))
  returning id into note_id;
  perform private.log_moderator_action(owner, 'photo_note_added', p_photo_id);
  return note_id;
end;
$$;

create function public.moderator_photo_notes(p_photo_id uuid)
returns table (note_id bigint, body text, moderator_id uuid, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if not private.moderator_can_see_photo(p_photo_id) then
    return;
  end if;
  return query
    select n.id, n.body, n.moderator_id, n.created_at
    from private.moderator_notes n
    where n.media_asset_id = p_photo_id
    order by n.created_at, n.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Moderator actions: audited, and safe against stale review items
-- ---------------------------------------------------------------------------

-- Replaces the pipeline version. Changes for moderators only:
--   * approve requires the photo to be waiting for manual review (not
--     failed, re-processing or already decided by someone else)
--   * reject requires a pending or approved photo (not already rejected)
--   * the audit row links the photo; removal is also a photo event
-- Service-role behaviour is unchanged.
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
  if asset.moderation_state in ('quarantined', 'removed', 'awaiting_upload')
     or exists (select 1 from private.profile_photos where id = p_photo_id and removed_at is not null) then
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
    if actor_type = 'moderator' and pp.stage is distinct from 'awaiting_manual_review' then
      raise exception 'photo is not awaiting a decision' using errcode = 'check_violation';
    end if;
    perform private.photo_apply_approval(p_photo_id, actor_type,
      case actor_type when 'moderator' then auth.uid() end, pp.attempts);
  elsif p_decision = 'reject' then
    if actor_type = 'moderator' and asset.moderation_state not in ('pending_scan', 'approved') then
      raise exception 'photo is not awaiting a decision' using errcode = 'check_violation';
    end if;
    perform private.photo_apply_rejection(p_photo_id, actor_type,
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
    perform private.log_photo_event(p_photo_id, 'removed', actor_type,
      case actor_type when 'moderator' then auth.uid() end);
  end if;

  if actor_type = 'moderator' then
    perform private.log_moderator_action(asset.owner_id, 'photo_' || p_decision, p_photo_id, p_reason);
  end if;
end;
$$;

-- Replaces the pipeline version: also refuses own photos and anything
-- restricted to child safety, and writes the moderator audit row.
create or replace function public.moderator_retry_photo_processing(p_photo_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid;
begin
  if not private.is_moderator() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if not private.moderator_can_see_photo(p_photo_id) then
    raise exception 'photo is not in a failed state';
  end if;
  update private.photo_processing pp
  set stage = 'uploaded', attempts = 0, next_attempt_at = now(), lease_expires_at = null, last_error_code = null
  where pp.photo_id = p_photo_id and pp.stage = 'processing_failed'
    and exists (select 1 from private.media_assets m
                where m.id = pp.photo_id and m.moderation_state = 'pending_scan');
  if not found then
    raise exception 'photo is not in a failed state';
  end if;
  select owner_id into owner from private.media_assets where id = p_photo_id;
  perform private.log_photo_event(p_photo_id, 'retry_requested', 'moderator', auth.uid());
  perform private.log_moderator_action(owner, 'photo_retry', p_photo_id);
end;
$$;

-- Replaces the pipeline version: same checks and result, plus the
-- moderator audit row. Only the Edge Function that issues signed URLs
-- needs to call it.
create or replace function public.moderator_photo_review_context(p_photo_id uuid)
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
  if asset.moderation_state in ('removed', 'awaiting_upload') then
    raise exception 'photo not found';
  end if;

  select s.media_object_path into verification_path
  from private.verification_sessions s
  where s.user_id = asset.owner_id and s.status = 'approved'
    and s.media_object_path is not null and s.media_deleted_at is null
  order by s.reviewed_at desc
  limit 1;

  perform private.log_photo_event(p_photo_id, 'verification_compare_accessed', 'moderator', auth.uid());
  perform private.log_moderator_action(asset.owner_id, 'photo_review_opened', p_photo_id);

  return jsonb_build_object(
    'profile_photo', jsonb_build_object('bucket_id', asset.bucket_id, 'object_path', asset.object_path),
    'verification_photo', case when verification_path is null then null
      else jsonb_build_object('bucket_id', 'verification-media', 'object_path', verification_path) end
  );
end;
$$;

-- Replaces the profile-photos version: records which moderator escalated
-- (the child-safety log records the case itself), and a second escalation
-- of the same photo doesn't open another case. The case id grants nothing
-- by itself: case contents need the child-safety reviewer role.
create or replace function public.flag_media_for_child_safety(p_media_asset_id uuid, p_category text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid;
  case_id uuid;
begin
  if not (private.is_moderator() or private.is_child_safety_reviewer()) then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_category not in ('suspected_csam', 'sexual_content_involving_possible_minor', 'underage_user_concern') then
    raise exception 'invalid category' using errcode = 'check_violation';
  end if;
  select owner_id into owner from private.media_assets where id = p_media_asset_id for update;
  if owner is null then
    raise exception 'unknown media asset';
  end if;
  if private.is_moderator() and owner = auth.uid() then
    raise exception 'moderators cannot act on their own account' using errcode = 'insufficient_privilege';
  end if;

  select c.id into case_id from private.child_safety_cases c
  where c.media_asset_id = p_media_asset_id
  order by c.created_at
  limit 1;
  if case_id is null then
    case_id := private.open_child_safety_case(owner, p_category, 'moderator', null, p_media_asset_id, true);
  end if;

  if private.is_moderator() then
    perform private.log_moderator_action(owner, 'photo_escalate_child_safety', p_media_asset_id);
  end if;
  return case_id;
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
  -- Moderator API: signed-in callers, checked for role + MFA inside.
  foreach fn in array array[
    'public.moderator_photos_awaiting_review(integer)',
    'public.moderator_photo_review_queue(integer)',
    'public.moderator_photo_review_item(uuid)',
    'public.moderator_add_photo_note(uuid, text)',
    'public.moderator_photo_notes(uuid)',
    'public.moderator_retry_photo_processing(uuid)',
    'public.moderator_photo_review_context(uuid)',
    'public.flag_media_for_child_safety(uuid, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;

revoke execute on function public.moderate_profile_photo(uuid, text, text) from public, anon;
grant execute on function public.moderate_profile_photo(uuid, text, text) to authenticated, service_role;
