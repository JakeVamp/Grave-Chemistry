-- Assertion helpers and identity switches for the SQL tests.

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.check(condition boolean, label text) returns void
language plpgsql as $$
begin
  if condition is distinct from true then
    raise exception 'FAILED: %', label;
  end if;
  raise notice 'ok - %', label;
end $$;

-- Runs sql and requires it to fail with an error containing `expected`
-- (message text or SQLSTATE).
create function tests.expect_error(sql text, expected text, label text) returns void
language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(expected in sqlerrm) > 0 or sqlstate = expected then
      raise notice 'ok - % (blocked: %)', label, sqlerrm;
      return;
    end if;
    raise exception 'FAILED: % (wrong error [%] %)', label, sqlstate, sqlerrm;
  end;
  raise exception 'FAILED: % (expected an error, statement succeeded)', label;
end $$;

grant execute on all functions in schema tests to anon, authenticated, service_role;

-- Switch identity: select tests.become('authenticated', '<uuid>', '{...extra claims}')
create function tests.become(p_role text, p_sub uuid default null, p_extra jsonb default '{}'::jsonb)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    (jsonb_build_object('role', p_role) || case when p_sub is null then '{}'::jsonb
      else jsonb_build_object('sub', p_sub) end || p_extra)::text, false);
  perform set_config('role', p_role, false);
end $$;

-- Back to the superuser (like the SQL Editor / a trusted backend).
create function tests.become_admin() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', false);
  perform set_config('request.jwt.claims', '', false);
end $$;
grant execute on function tests.become_admin() to anon, authenticated, service_role;

-- Seed users
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com'),
  ('99999999-9999-9999-9999-999999999999', 'mod@example.com');

-- Creates (or completes) a user who meets every Discovery requirement.
create function tests.make_eligible(p_id uuid, p_name text) returns void
language plpgsql as $$
begin
  insert into auth.users (id, email, email_confirmed_at)
  values (p_id, lower(p_name) || '@example.com', now())
  on conflict (id) do update set email_confirmed_at = now();
  insert into public.profiles (id, display_name, birth_date, location_city,
    location_state_or_region, gender, community_identity, dating_preference)
  values (p_id, p_name, '1990-01-01', 'Salem', 'MA', 'woman', 'goth', 'goth_seeking_goth')
  on conflict (id) do nothing;
  update public.profiles set verification_status = 'verified' where id = p_id;
  update private.accounts set status = 'active' where user_id = p_id;
end $$;

-- Runs one photo through the processing pipeline as the service-role
-- worker, with synthetic findings. Returns the pipeline outcome.
create function tests.process_photo(
  p_photo uuid,
  p_child_safety text default 'clear',
  p_moderation text default 'approve',
  p_sha text default null,
  p_phash text default null
) returns text language plpgsql as $$
declare
  claimed record;
  outcome jsonb;
  sha text;
  phash text;
begin
  perform tests.become_admin();
  sha := coalesce(p_sha, encode(extensions.digest(p_photo::text, 'sha256'), 'hex'));
  phash := coalesce(p_phash, (select string_agg(case when get_bit(extensions.digest(p_photo::text, 'sha256'), i) = 1 then '1' else '0' end, '')
                              from generate_series(0, 63) i));
  perform tests.become('service_role', null);
  select * into claimed from public.pipeline_claim_photos(50) c where c.photo_id = p_photo;
  if claimed is null then
    perform tests.become_admin();
    return 'not_claimed';
  end if;
  outcome := public.pipeline_submit_result(p_photo, claimed.attempt, jsonb_build_object(
    'validation', jsonb_build_object('ok', true, 'width', 1200, 'height', 1600, 'bytes', 1000),
    'fingerprints', jsonb_build_object('sha256', sha, 'perceptual_hash', phash),
    'child_safety', jsonb_build_object('result', p_child_safety),
    'moderation', jsonb_build_object('result', p_moderation)));
  perform tests.become_admin();
  return outcome ->> 'outcome';
end $$;

-- Uploads a synthetic photo (a storage row, no image data) as the given
-- user; returns the photo id.
create function tests.upload_photo(p_user uuid, p_size integer default 1000) returns uuid language plpgsql as $$
declare
  r jsonb;
begin
  perform tests.become('authenticated', p_user);
  r := public.begin_profile_photo_upload();
  insert into storage.objects (bucket_id, name, owner_id, metadata)
  values ('profile-photos', r ->> 'object_path', p_user::text,
          jsonb_build_object('size', p_size, 'mimetype', 'image/jpeg'));
  perform public.complete_profile_photo_upload((r ->> 'asset_id')::uuid);
  perform tests.become_admin();
  return (r ->> 'asset_id')::uuid;
end $$;

-- Claims a photo as the worker and submits an arbitrary result.
create function tests.submit_raw(p_photo uuid, p_result jsonb) returns jsonb language plpgsql as $$
declare
  claimed record;
  outcome jsonb;
begin
  perform tests.become('service_role', null);
  select * into claimed from public.pipeline_claim_photos(50) c where c.photo_id = p_photo;
  if claimed is null then
    perform tests.become_admin();
    return '{"outcome": "not_claimed"}';
  end if;
  outcome := public.pipeline_submit_result(p_photo, claimed.attempt, p_result);
  perform tests.become_admin();
  return outcome || jsonb_build_object('attempt', claimed.attempt);
end $$;
