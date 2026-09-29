-- Grave Chemistry: public profile photos
--
-- A separate system from live verification:
--   * its own private Storage bucket (`profile-photos`); verification
--     evidence stays in `verification-media` and can't be read back or
--     copied into profile photos
--   * `private.media_assets` (from the trust & safety migration) remains the
--     safety record: moderation state, quarantine, duplicate fingerprints
--   * `private.profile_photos` holds the user's arrangement: order, primary
--     photo and soft removal
--
-- Nobody sees a photo until it is approved by the moderation pipeline and
-- every visibility check passes. All user actions go through RPCs; users
-- have no table access.

-- ---------------------------------------------------------------------------
-- Verification evidence can no longer be read back by its owner
-- ---------------------------------------------------------------------------
-- The app never downloads verification photos. Without read access they
-- also can't be copied (Storage copy) into a profile-photo upload.

drop policy "Verification media: owner can read own" on storage.objects;

-- ---------------------------------------------------------------------------
-- Hardening: service-role checks require the real database role
-- ---------------------------------------------------------------------------
-- Previously the JWT claim alone was checked. Supabase signs JWTs, so the
-- claim can't be forged, but requiring the actual `service_role` database
-- role as well means a claim can never unlock service-only paths through a
-- function that is callable by signed-in users.

create or replace function private.is_service_role()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(private.jwt_claims() ->> 'role', '') = 'service_role'
     and coalesce(current_setting('role', true), '') = 'service_role'
$$;

-- ---------------------------------------------------------------------------
-- Settings, signal types, rate limits
-- ---------------------------------------------------------------------------

alter table private.security_settings
  add column max_profile_photos integer not null default 6,
  add column profile_photo_upload_window interval not null default interval '30 minutes',
  add column photo_replacement_window interval not null default interval '7 days',
  add column photo_replacement_threshold integer not null default 3;

insert into private.abuse_signal_types (code, category, weight, description) values
  ('photo_replacement', 'profile_change', 2, 'Many new photos in a short time after verification');

insert into private.rate_limit_rules (action, max_events, per_window, description) values
  ('profile_photo_upload', 20, interval '1 day', 'Profile photo uploads started per day');

alter table private.moderation_actions
  drop constraint moderation_actions_action_check,
  add constraint moderation_actions_action_check check (action in (
    'dismiss', 'warn', 'restrict', 'suspend', 'ban', 'require_reverification',
    'lift_restriction', 'clear_review', 'photo_approve', 'photo_reject', 'photo_remove'
  ));

-- Uploads start as `awaiting_upload` until the file arrives.
alter table private.media_assets
  drop constraint media_assets_moderation_state_check,
  add constraint media_assets_moderation_state_check check (moderation_state in (
    'awaiting_upload', 'pending_scan', 'approved', 'rejected', 'quarantined', 'removed'
  )),
  add column updated_at timestamptz not null default now();

-- ---------------------------------------------------------------------------
-- Storage bucket
-- ---------------------------------------------------------------------------
-- Private even though the photos are meant for other users: approved photos
-- are served only through signed URLs, which Storage issues only when the
-- select policy below allows it.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('profile-photos', 'profile-photos', false, 5242880, array['image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- Photo arrangement
-- ---------------------------------------------------------------------------

create table private.profile_photos (
  -- Same id as the media asset: one safety record per photo.
  id             uuid primary key references private.media_assets (id) on delete cascade,
  user_id        uuid not null references auth.users (id) on delete cascade,
  position       integer not null check (position >= 1),
  is_primary     boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  removed_at     timestamptz,
  removed_by     text check (removed_by in ('user', 'moderator', 'system')),
  removal_reason text check (char_length(removal_reason) <= 200),
  check ((removed_at is null) = (removed_by is null))
);

create index profile_photos_user_idx on private.profile_photos (user_id, position)
  where removed_at is null;

-- At most one primary among active photos...
create unique index profile_photos_one_primary_idx
  on private.profile_photos (user_id) where is_primary and removed_at is null;

-- ...and exactly one whenever photos exist, checked at commit so functions
-- can move the primary within a transaction. Deferred triggers run as the
-- calling user at commit, hence SECURITY DEFINER.
create function private.profile_photos_check_primary()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  subject uuid := coalesce(new.user_id, old.user_id);
  active integer;
  primaries integer;
begin
  select count(*), count(*) filter (where is_primary)
    into active, primaries
  from private.profile_photos
  where user_id = subject and removed_at is null;
  if active > 0 and primaries <> 1 then
    raise exception 'exactly one primary photo is required' using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

create constraint trigger profile_photos_check_primary
  after insert or update or delete on private.profile_photos
  deferrable initially deferred
  for each row execute function private.profile_photos_check_primary();

-- Ownership and creation time never change; removal is one-way.
create function private.profile_photos_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id <> old.id or new.user_id <> old.user_id or new.created_at <> old.created_at then
    raise exception 'photo ownership is immutable' using errcode = 'insufficient_privilege';
  end if;
  if old.removed_at is not null and new.removed_at is null then
    raise exception 'removed photos cannot be restored' using errcode = 'insufficient_privilege';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger profile_photos_guard
  before update on private.profile_photos
  for each row execute function private.profile_photos_guard();

-- Keep a media asset's updated_at current.
create function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger media_assets_touch_updated_at
  before update on private.media_assets
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------

-- A photo other users may see: approved, active, and the owner passes every
-- eligibility check (verified, active, not under review, no safety hold).
-- Quarantined, rejected, pending and removed media are never approved.
create function private.profile_photo_is_servable(p_photo_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from private.profile_photos p
    where p.id = p_photo_id
      and p.removed_at is null
      and private.media_is_publicly_servable(p.id)
  )
$$;

-- Whether the caller may view a photo: owners see their own photos unless
-- quarantined or removed; others need a servable photo, their own
-- eligibility and no block either way.
create function private.can_view_profile_photo(p_photo_id uuid, p_viewer uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from private.profile_photos p
    join private.media_assets m on m.id = p.id
    where p.id = p_photo_id
      and p.removed_at is null
      and (
        (p.user_id = p_viewer and m.moderation_state not in ('quarantined', 'removed'))
        or (
          p_viewer is not null
          and p.user_id <> p_viewer
          and private.profile_photo_is_servable(p.id)
          and private.is_discovery_eligible(p_viewer)
          and not private.is_blocked_between(p_viewer, p.user_id)
        )
      )
  )
$$;

-- ---------------------------------------------------------------------------
-- Storage policies
-- ---------------------------------------------------------------------------
-- Object names are `<asset uuid>/<32 random hex>.jpg`.

create function private.can_upload_profile_photo_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.jpg$'
    then exists (
      select 1 from private.media_assets m
      where m.id = split_part(p_name, '/', 1)::uuid
        and m.owner_id = auth.uid()
        and m.bucket_id = 'profile-photos'
        and m.object_path = p_name
        and m.moderation_state = 'awaiting_upload'
        and m.created_at > now() - (private.settings()).profile_photo_upload_window
    )
    else false
  end
$$;

create function private.can_read_profile_photo_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.jpg$'
    then exists (
      select 1 from private.media_assets m
      where m.id = split_part(p_name, '/', 1)::uuid
        and m.bucket_id = 'profile-photos'
        and m.object_path = p_name
        and private.can_view_profile_photo(m.id, auth.uid())
    )
    else false
  end
$$;

create policy "Profile photos: upload into own pending slot"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'profile-photos'
    and private.can_upload_profile_photo_object(name)
  );

-- Reading an object (and so creating a signed URL for it) follows the
-- visibility rules above.
create policy "Profile photos: read when visible"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'profile-photos'
    and private.can_read_profile_photo_object(name)
  );

-- No update or delete policies: files can't be swapped after upload, and
-- removal goes through the deletion queue.

-- ---------------------------------------------------------------------------
-- User RPCs
-- ---------------------------------------------------------------------------

create function private.active_photo_count(p_user_id uuid)
returns integer
language sql
stable
set search_path = ''
as $$
  select (
    select count(*) from private.profile_photos
    where user_id = p_user_id and removed_at is null
  )::integer + (
    select count(*) from private.media_assets
    where owner_id = p_user_id
      and bucket_id = 'profile-photos'
      and moderation_state = 'awaiting_upload'
      and created_at > now() - (private.settings()).profile_photo_upload_window
  )::integer
$$;

-- Reserves an upload slot. Returns {outcome, asset_id, object_path}.
create function public.begin_profile_photo_upload()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  cfg private.security_settings := private.settings();
  asset_id uuid := gen_random_uuid();
  path text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;
  if private.has_active_safety_hold(uid)
     or (select status from private.accounts where user_id = uid) in ('restricted', 'suspended', 'banned', 'deletion_pending') then
    return jsonb_build_object('outcome', 'not_allowed');
  end if;
  if private.active_photo_count(uid) >= cfg.max_profile_photos then
    return jsonb_build_object('outcome', 'limit_reached', 'max_photos', cfg.max_profile_photos);
  end if;
  if not private.try_consume_rate_limit('profile_photo_upload', uid::text) then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;

  path := asset_id::text || '/' || encode(extensions.gen_random_bytes(16), 'hex') || '.jpg';
  insert into private.media_assets (id, owner_id, purpose, bucket_id, object_path, moderation_state)
  values (asset_id, uid, 'profile_photo', 'profile-photos', path, 'awaiting_upload');

  return jsonb_build_object('outcome', 'ready', 'asset_id', asset_id, 'object_path', path);
end;
$$;

-- Confirms the upload arrived and adds the photo (pending review).
create function public.complete_profile_photo_upload(p_asset_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  cfg private.security_settings := private.settings();
  asset private.media_assets;
  next_position integer;
  has_primary boolean;
  recent_new integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;

  select * into asset from private.media_assets
  where id = p_asset_id and owner_id = uid and bucket_id = 'profile-photos'
  for update;
  if not found or asset.moderation_state <> 'awaiting_upload' then
    return jsonb_build_object('outcome', 'not_found');
  end if;
  if not exists (
    select 1 from storage.objects
    where bucket_id = 'profile-photos' and name = asset.object_path and owner_id = uid::text
  ) then
    return jsonb_build_object('outcome', 'upload_missing');
  end if;

  update private.media_assets set moderation_state = 'pending_scan' where id = asset.id;

  select coalesce(max(position), 0) + 1, coalesce(bool_or(is_primary), false)
    into next_position, has_primary
  from private.profile_photos where user_id = uid and removed_at is null;

  insert into private.profile_photos (id, user_id, position, is_primary)
  values (asset.id, uid, next_position, not has_primary);

  -- Photo changes are significant: they reset "established" trust, and a
  -- burst of new photos after verification is flagged for review. Every
  -- new photo also needs moderation approval before anyone sees it.
  if (select verification_status from public.profiles where id = uid) = 'verified' then
    insert into private.profile_change_events (user_id, change_kind, field)
    values (uid, 'photo', 'profile_photo');

    select count(*) into recent_new from private.profile_change_events
    where user_id = uid and change_kind = 'photo'
      and created_at > now() - cfg.photo_replacement_window;
    if recent_new >= cfg.photo_replacement_threshold then
      perform private.record_abuse_signal(uid, 'photo_replacement', 'medium',
        jsonb_build_object('new_photos', recent_new), null, 'system');
    end if;
  end if;

  return jsonb_build_object('outcome', 'added', 'photo_id', asset.id);
end;
$$;

-- The caller's own photos with a coarse status only. Moderation reasons,
-- fingerprints and child-safety details are never returned; quarantine
-- shows as "in_review".
create function public.my_profile_photos()
returns table (photo_id uuid, object_path text, "position" integer, is_primary boolean, status text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id,
         case when m.moderation_state = 'quarantined' then null else m.object_path end,
         p.position,
         p.is_primary,
         case m.moderation_state
           when 'approved' then 'live'
           when 'rejected' then 'not_approved'
           else 'in_review'
         end
  from private.profile_photos p
  join private.media_assets m on m.id = p.id
  where p.user_id = auth.uid() and p.removed_at is null
  order by p.position
$$;

-- Another user's servable photos, in order, for a viewer allowed to see
-- them. Empty otherwise (the reason is never revealed).
create function public.get_profile_photos(p_user_id uuid)
returns table (photo_id uuid, object_path text, "position" integer, is_primary boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, m.object_path, p.position, p.is_primary
  from private.profile_photos p
  join private.media_assets m on m.id = p.id
  where p.user_id = p_user_id
    and auth.uid() is not null
    and private.can_view_profile_photo(p.id, auth.uid())
  order by p.position
$$;

-- Removes one of the caller's photos. Photos under review for child safety
-- (or while the account is on a safety hold) can't be removed, so evidence
-- is preserved.
create function public.delete_profile_photo(p_photo_id uuid)
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
  insert into private.media_deletion_queue (bucket_id, object_path)
  values (asset.bucket_id, asset.object_path);

  -- Close gaps in the order and keep exactly one primary.
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

-- Sets the order. `p_photo_ids` must list exactly the caller's active
-- photos.
create function public.reorder_profile_photos(p_photo_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid constant uuid := auth.uid();
  owned uuid[];
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(array_agg(id order by id), '{}') into owned
  from private.profile_photos where user_id = uid and removed_at is null;

  if cardinality(p_photo_ids) <> cardinality(owned)
     or (select array_agg(x order by x) from unnest(p_photo_ids) x) is distinct from owned then
    raise exception 'order must contain exactly your current photos' using errcode = 'check_violation';
  end if;

  update private.profile_photos p
  set position = o.ordinality
  from unnest(p_photo_ids) with ordinality as o(id, ordinality)
  where p.id = o.id and p.user_id = uid;
end;
$$;

create function public.set_primary_profile_photo(p_photo_id uuid)
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
  if not exists (select 1 from private.profile_photos
                 where id = p_photo_id and user_id = uid and removed_at is null) then
    raise exception 'photo not found' using errcode = 'check_violation';
  end if;
  update private.profile_photos set is_primary = false
  where user_id = uid and removed_at is null and is_primary and id <> p_photo_id;
  update private.profile_photos set is_primary = true where id = p_photo_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Trusted moderation paths
-- ---------------------------------------------------------------------------

-- The automated pipeline (service role) or a moderator (role + MFA) decides
-- on a pending photo. Quarantined photos can't be touched here.
create function public.moderate_profile_photo(p_photo_id uuid, p_decision text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_type text;
  asset private.media_assets;
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

  if p_decision = 'approve' then
    update private.media_assets set moderation_state = 'approved', published_at = now()
    where id = p_photo_id;
  elsif p_decision = 'reject' then
    update private.media_assets set moderation_state = 'rejected' where id = p_photo_id;
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
  end if;

  if actor_type = 'moderator' then
    insert into private.moderation_actions (target_user_id, action, reason, moderator_id)
    values (asset.owner_id, 'photo_' || p_decision, left(p_reason, 500), auth.uid());
  end if;
end;
$$;

-- The upload pipeline records the fingerprints it computed. Cross-account
-- matches become review signals (see private.register_media_hashes).
create function public.record_profile_photo_fingerprints(
  p_photo_id uuid,
  p_sha256 text,
  p_perceptual_hash text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_service_role() then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_perceptual_hash !~ '^[01]{64}$' then
    raise exception 'perceptual hash must be 64 bits' using errcode = 'check_violation';
  end if;
  return private.register_media_hashes(p_photo_id, p_sha256, p_perceptual_hash::bit(64));
end;
$$;

-- A moderator or child-safety reviewer escalates a photo to child safety:
-- the photo is quarantined, the account held and a case opened.
create function public.flag_media_for_child_safety(p_media_asset_id uuid, p_category text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner uuid;
begin
  if not (private.is_moderator() or private.is_child_safety_reviewer()) then
    raise exception 'not_authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_category not in ('suspected_csam', 'sexual_content_involving_possible_minor', 'underage_user_concern') then
    raise exception 'invalid category' using errcode = 'check_violation';
  end if;
  select owner_id into owner from private.media_assets where id = p_media_asset_id;
  if owner is null then
    raise exception 'unknown media asset';
  end if;
  return private.open_child_safety_case(owner, p_category, 'moderator', null, p_media_asset_id, true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Account deletion: queue profile photo files
-- ---------------------------------------------------------------------------
-- Quarantined media is preserved: deleting an account with quarantined
-- media fails (media_quarantine restricts deletion) until child-safety
-- review decides, which is intended.

create function private.queue_profile_photo_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.media_deletion_queue (bucket_id, object_path)
  select bucket_id, object_path from private.media_assets
  where owner_id = old.id and bucket_id = 'profile-photos'
    and moderation_state not in ('removed', 'quarantined');
  return old;
end;
$$;

create trigger on_auth_user_deleted_queue_profile_photos
  before delete on auth.users
  for each row execute function private.queue_profile_photo_deletion();

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
  foreach fn in array array[
    'public.begin_profile_photo_upload()',
    'public.complete_profile_photo_upload(uuid)',
    'public.my_profile_photos()',
    'public.get_profile_photos(uuid)',
    'public.delete_profile_photo(uuid)',
    'public.reorder_profile_photos(uuid[])',
    'public.set_primary_profile_photo(uuid)',
    'public.moderate_profile_photo(uuid, text, text)',
    'public.flag_media_for_child_safety(uuid, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end $$;

revoke execute on function public.record_profile_photo_fingerprints(uuid, text, text) from public, anon, authenticated;
grant execute on function public.record_profile_photo_fingerprints(uuid, text, text) to service_role;
grant execute on function public.moderate_profile_photo(uuid, text, text) to service_role;
