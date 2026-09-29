-- Grave Chemistry: child-safety foundation
--
-- Kept separate from ordinary moderation. Provides:
--   * protected child-safety categories and high-priority cases
--   * immediate account safety holds (hide from Discovery, likes, messages)
--   * media quarantine that ordinary users and moderators can't lift
--   * a dedicated child-safety reviewer role (claim + MFA)
--   * an append-only event log, including every evidence access
--   * an integration boundary for trusted hash-matching providers
--
-- This migration does NOT identify CSAM itself and never contacts external
-- organisations. Detection comes from trusted providers or reports; review
-- and legal/reporting decisions are separate human steps (see
-- docs/security/child-safety.md).

-- ---------------------------------------------------------------------------
-- Report categories
-- ---------------------------------------------------------------------------

insert into private.report_categories (code, priority, is_child_safety, description) values
  ('suspected_csam',          'critical', true, 'Suspected child sexual abuse material'),
  ('adult_soliciting_minor',  'critical', true, 'Adult contacting or soliciting a minor'),
  ('grooming_concern',        'critical', true, 'Grooming concern');

update private.report_categories set priority = 'critical' where code = 'underage_concern';

-- ---------------------------------------------------------------------------
-- Reviewer role
-- ---------------------------------------------------------------------------
-- Separate from ordinary moderators. Granted only through the Admin API
-- (app_metadata.role) and usable only with MFA.

create function private.is_child_safety_reviewer()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(private.jwt_claims() -> 'app_metadata' ->> 'role', '') = 'child_safety_reviewer'
     and coalesce(private.jwt_claims() ->> 'aal', '') = 'aal2'
$$;

-- ---------------------------------------------------------------------------
-- Cases, holds, quarantine, events
-- ---------------------------------------------------------------------------

create table private.child_safety_cases (
  id                  uuid primary key default gen_random_uuid(),
  -- No foreign keys: cases and evidence references must survive account
  -- deletion for preservation obligations.
  subject_user_id     uuid not null,
  category            text not null check (category in (
    'suspected_csam',
    'known_csam_hash_match',
    'sexual_content_involving_possible_minor',
    'underage_user_concern',
    'adult_soliciting_minor',
    'grooming_concern'
  )),
  priority            text not null check (priority in ('high', 'critical')),
  source              text not null check (source in (
    'user_report', 'hash_match_provider', 'classifier_provider', 'moderator', 'system'
  )),
  report_id           uuid,
  media_asset_id      uuid,
  status              text not null default 'open' check (status in (
    'open', 'under_review', 'escalated_legal', 'closed_no_violation', 'closed_actioned'
  )),
  -- Preservation flag for legal process; set for suspected/known CSAM.
  legal_hold          boolean not null default false,
  -- Reference recorded by the legal/reporting team after a human decision.
  external_report_reference text check (char_length(external_report_reference) <= 200),
  assigned_reviewer   uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index child_safety_cases_queue_idx
  on private.child_safety_cases (priority desc, created_at)
  where status in ('open', 'under_review', 'escalated_legal');
create index child_safety_cases_subject_idx on private.child_safety_cases (subject_user_id);

create table private.account_safety_holds (
  id           bigint generated always as identity primary key,
  user_id      uuid not null,
  case_id      uuid not null references private.child_safety_cases (id),
  applied_at   timestamptz not null default now(),
  released_at  timestamptz,
  released_by  uuid
);

create unique index account_safety_holds_one_per_case_idx
  on private.account_safety_holds (case_id);
create index account_safety_holds_active_idx
  on private.account_safety_holds (user_id) where released_at is null;

create table private.media_quarantine (
  media_asset_id  uuid primary key references private.media_assets (id) on delete restrict,
  case_id         uuid not null references private.child_safety_cases (id),
  quarantined_at  timestamptz not null default now(),
  released_at     timestamptz,
  released_by     uuid
);

create table private.child_safety_events (
  id          bigint generated always as identity primary key,
  case_id     uuid not null,
  event_type  text not null check (event_type in (
    'case_opened', 'media_quarantined', 'account_hold_applied', 'evidence_accessed',
    'status_changed', 'hold_released', 'quarantine_released', 'legal_hold_set',
    'external_report_recorded'
  )),
  actor_type  text not null check (actor_type in ('user', 'system', 'provider', 'child_safety_reviewer')),
  actor_id    uuid,
  created_at  timestamptz not null default now(),
  -- Reason codes only. Never image data, paths, URLs or report text.
  details     jsonb not null default '{}'::jsonb check (pg_column_size(details) <= 1024)
);

create index child_safety_events_case_idx on private.child_safety_events (case_id, created_at);

create trigger child_safety_events_append_only
  before update or delete on private.child_safety_events
  for each row execute function private.forbid_modification();

-- Holds and quarantine records can only be released (released_at set),
-- never deleted or re-pointed.
create function private.safety_record_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% records cannot be deleted', tg_table_name using errcode = 'insufficient_privilege';
  end if;
  if old.released_at is not null or new.case_id <> old.case_id then
    raise exception '% records are immutable once released', tg_table_name
      using errcode = 'insufficient_privilege';
  end if;
  if new.released_at is not null
     and coalesce(current_setting('app.child_safety_release', true), '') <> 'on' then
    raise exception 'only child-safety review can release %', tg_table_name
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger account_safety_holds_guard
  before update or delete on private.account_safety_holds
  for each row execute function private.safety_record_guard();
create trigger media_quarantine_guard
  before update or delete on private.media_quarantine
  for each row execute function private.safety_record_guard();

-- Replaces the placeholder from the trust & safety migration.
create or replace function private.has_active_safety_hold(p_user_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from private.account_safety_holds
    where user_id = p_user_id and released_at is null
  )
$$;

create function private.log_child_safety_event(
  p_case_id uuid,
  p_event_type text,
  p_actor_type text,
  p_actor_id uuid default null,
  p_details jsonb default '{}'::jsonb
)
returns void
language sql
set search_path = ''
as $$
  insert into private.child_safety_events (case_id, event_type, actor_type, actor_id, details)
  values (p_case_id, p_event_type, p_actor_type, p_actor_id, coalesce(p_details, '{}'::jsonb))
$$;

-- Opens a case. Serious categories immediately hold the account and
-- quarantine any linked media; the hold hides the account everywhere
-- server-side until a child-safety reviewer decides.
create function private.open_child_safety_case(
  p_subject_user_id uuid,
  p_category text,
  p_source text,
  p_report_id uuid default null,
  p_media_asset_id uuid default null,
  p_apply_hold boolean default true
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  case_id uuid;
  is_csam constant boolean := p_category in ('suspected_csam', 'known_csam_hash_match',
                                             'sexual_content_involving_possible_minor');
begin
  insert into private.child_safety_cases
    (subject_user_id, category, priority, source, report_id, media_asset_id, legal_hold)
  values (
    p_subject_user_id, p_category,
    case when is_csam or p_category = 'adult_soliciting_minor' then 'critical' else 'high' end,
    p_source, p_report_id, p_media_asset_id, is_csam
  )
  returning id into case_id;

  perform private.log_child_safety_event(case_id, 'case_opened',
    case p_source when 'user_report' then 'user'
                  when 'hash_match_provider' then 'provider'
                  when 'classifier_provider' then 'provider'
                  else 'system' end,
    null, jsonb_build_object('category', p_category));
  if is_csam then
    perform private.log_child_safety_event(case_id, 'legal_hold_set', 'system');
  end if;

  if p_media_asset_id is not null then
    update private.media_assets set moderation_state = 'quarantined'
    where id = p_media_asset_id;
    insert into private.media_quarantine (media_asset_id, case_id)
    values (p_media_asset_id, case_id)
    on conflict (media_asset_id) do nothing;
    perform private.log_child_safety_event(case_id, 'media_quarantined', 'system');
  end if;

  if p_apply_hold then
    insert into private.account_safety_holds (user_id, case_id) values (p_subject_user_id, case_id);
    perform private.log_child_safety_event(case_id, 'account_hold_applied', 'system');
  end if;

  return case_id;
end;
$$;

-- Child-safety reports go to their own queue. A hold is applied at once for
-- CSAM or solicitation reports, and for underage/grooming concerns once two
-- different people have reported the same account (so a single malicious
-- report can't silently remove someone, while repeated concerns act fast).
create function private.route_child_safety_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  cs_category text;
  reporters integer;
begin
  if not exists (select 1 from private.report_categories
                 where code = new.category and is_child_safety) then
    return new;
  end if;

  cs_category := case new.category
    when 'underage_concern' then 'underage_user_concern'
    else new.category end;

  select count(distinct reporter_id) into reporters
  from private.user_reports
  where reported_user_id = new.reported_user_id
    and category = new.category
    and created_at > now() - interval '30 days';

  perform private.open_child_safety_case(
    new.reported_user_id, cs_category, 'user_report', new.id, null,
    new.category in ('suspected_csam', 'adult_soliciting_minor') or reporters >= 2
  );
  return new;
end;
$$;

create trigger user_reports_route_child_safety
  after insert on private.user_reports
  for each row execute function private.route_child_safety_report();

-- ---------------------------------------------------------------------------
-- Provider boundary (service role only)
-- ---------------------------------------------------------------------------
-- Called by the trusted upload backend after a child-safety hash-matching or
-- classification provider returns a result for a media asset. The media is
-- quarantined and the account held; nothing is sent externally.

create function public.report_child_safety_media_match(
  p_media_asset_id uuid,
  p_match_type text,
  p_provider_reference text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid;
  case_id uuid;
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_match_type not in ('known_csam_hash_match', 'suspected_csam',
                          'sexual_content_involving_possible_minor') then
    raise exception 'invalid match type' using errcode = 'check_violation';
  end if;
  select owner_id into owner from private.media_assets where id = p_media_asset_id;
  if owner is null then
    raise exception 'unknown media asset';
  end if;

  case_id := private.open_child_safety_case(
    owner, p_match_type,
    case when p_match_type = 'known_csam_hash_match' then 'hash_match_provider' else 'classifier_provider' end,
    null, p_media_asset_id, true);
  perform private.log_child_safety_event(case_id, 'status_changed', 'provider', null,
    jsonb_build_object('provider_reference', left(coalesce(p_provider_reference, ''), 100)));
  return case_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Child-safety reviewer functions
-- ---------------------------------------------------------------------------

-- Returns the storage location of a case's quarantined media so a trusted
-- backend can issue a very short-lived signed URL. Every call is audited.
-- Ordinary moderators are refused.
create function public.child_safety_access_evidence(p_case_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  asset private.media_assets;
begin
  if not private.is_child_safety_reviewer() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  select m.* into asset
  from private.child_safety_cases c
  join private.media_assets m on m.id = c.media_asset_id
  where c.id = p_case_id;

  perform private.log_child_safety_event(p_case_id, 'evidence_accessed',
    'child_safety_reviewer', auth.uid());

  if asset.id is null then
    return null;
  end if;
  return jsonb_build_object('bucket_id', asset.bucket_id, 'object_path', asset.object_path);
end;
$$;

create function public.child_safety_update_case(p_case_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_child_safety_reviewer() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_status not in ('under_review', 'escalated_legal', 'closed_no_violation', 'closed_actioned') then
    raise exception 'invalid status' using errcode = 'check_violation';
  end if;
  update private.child_safety_cases
  set status = p_status, updated_at = now(), assigned_reviewer = coalesce(assigned_reviewer, auth.uid())
  where id = p_case_id;
  if not found then
    raise exception 'case not found';
  end if;
  perform private.log_child_safety_event(p_case_id, 'status_changed',
    'child_safety_reviewer', auth.uid(), jsonb_build_object('status', p_status));
end;
$$;

-- Releases the account hold and/or media quarantine for a case after
-- review. Media under legal hold can't be released back to users.
create function public.child_safety_release(p_case_id uuid, p_release_media boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  cs private.child_safety_cases;
begin
  if not private.is_child_safety_reviewer() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  select * into cs from private.child_safety_cases where id = p_case_id;
  if not found then
    raise exception 'case not found';
  end if;
  if cs.status <> 'closed_no_violation' then
    raise exception 'close the case as no violation before releasing';
  end if;
  if p_release_media and cs.legal_hold then
    raise exception 'media under legal hold cannot be released';
  end if;

  perform set_config('app.child_safety_release', 'on', true);

  update private.account_safety_holds
  set released_at = now(), released_by = auth.uid()
  where case_id = p_case_id and released_at is null;
  perform private.log_child_safety_event(p_case_id, 'hold_released', 'child_safety_reviewer', auth.uid());

  if p_release_media and cs.media_asset_id is not null then
    update private.media_quarantine
    set released_at = now(), released_by = auth.uid()
    where media_asset_id = cs.media_asset_id and released_at is null;
    update private.media_assets set moderation_state = 'pending_scan' where id = cs.media_asset_id;
    perform private.log_child_safety_event(p_case_id, 'quarantine_released', 'child_safety_reviewer', auth.uid());
  end if;

  perform set_config('app.child_safety_release', 'off', true);
end;
$$;

-- Records the reference of an external report made by the legal/reporting
-- team after a human decision. Nothing is sent from the database.
create function public.child_safety_record_external_report(p_case_id uuid, p_reference text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_child_safety_reviewer() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  update private.child_safety_cases
  set external_report_reference = left(p_reference, 200), updated_at = now()
  where id = p_case_id and status = 'escalated_legal';
  if not found then
    raise exception 'case must be escalated to legal first';
  end if;
  perform private.log_child_safety_event(p_case_id, 'external_report_recorded',
    'child_safety_reviewer', auth.uid());
end;
$$;

-- ---------------------------------------------------------------------------
-- Evidence bucket
-- ---------------------------------------------------------------------------
-- Private bucket with no policies at all: only the service role (via a
-- reviewer-gated backend) can touch it. Quarantined objects are moved here
-- through the Storage API.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('child-safety-evidence', 'child-safety-evidence', false, 20971520, null)
on conflict (id) do update set public = false;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke all on all tables in schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on function private.can_write_verification_object(text) to authenticated;
grant execute on function private.owns_verification_object(text) to authenticated;

revoke execute on function public.report_child_safety_media_match(uuid, text, text) from public, anon, authenticated;
grant execute on function public.report_child_safety_media_match(uuid, text, text) to service_role;

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.child_safety_access_evidence(uuid)',
    'public.child_safety_update_case(uuid, text)',
    'public.child_safety_release(uuid, boolean)',
    'public.child_safety_record_external_report(uuid, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;
