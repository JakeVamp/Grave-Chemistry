-- Public profile photos: ownership, upload slots, visibility gating,
-- moderation, quarantine, duplicates, separation from verification media.
-- Storage objects are synthetic rows; no image files are used.

\set alice '''11111111-1111-1111-1111-111111111111'''
\set bob '''22222222-2222-2222-2222-222222222222'''
\set carol '''33333333-3333-3333-3333-333333333333'''
\set dave '''44444444-4444-4444-4444-444444444444'''
\set erin '''55555555-5555-5555-5555-555555555555'''
\set mod '''99999999-9999-9999-9999-999999999999'''
\set mod_claims '''{"app_metadata": {"role": "moderator"}, "aal": "aal2"}'''

select tests.make_eligible(:alice, 'Alice');
select tests.make_eligible(:bob, 'Bob');
select tests.make_eligible(:carol, 'Carol');
insert into auth.users (id, email) values (:dave, 'dave@example.com');
insert into auth.users (id, email, email_confirmed_at) values (:erin, 'erin@example.com', now());
insert into public.profiles (id, display_name, birth_date, location_city, location_state_or_region,
  gender, community_identity, dating_preference)
values (:erin, 'Erin', '1992-01-01', 'Salem', 'MA', 'agender', 'normie', 'normie_seeking_goth');

-- Uploads a synthetic photo as the given user; returns the photo id.
create function tests.upload_photo(p_user uuid) returns uuid language plpgsql as $$
declare
  r jsonb;
begin
  perform tests.become('authenticated', p_user);
  r := public.begin_profile_photo_upload();
  insert into storage.objects (bucket_id, name, owner_id)
  values ('profile-photos', r ->> 'object_path', p_user::text);
  perform public.complete_profile_photo_upload((r ->> 'asset_id')::uuid);
  perform tests.become_admin();
  return (r ->> 'asset_id')::uuid;
end $$;

create function tests.approve(p_photo uuid) returns void language plpgsql as $$
begin
  perform tests.become('service_role', null);
  perform public.moderate_profile_photo(p_photo, 'approve');
  perform tests.become_admin();
end $$;

select tests.check((select public = false and file_size_limit = 5242880 and allowed_mime_types = array['image/jpeg']
  from storage.buckets where id = 'profile-photos'), 'profile photo bucket is private, 5 MB, JPEG only');

-- ---------------------------------------------------------------- upload slots
select tests.become('authenticated', :alice);
select public.begin_profile_photo_upload() as up \gset
select (:'up'::jsonb ->> 'asset_id') as a1, (:'up'::jsonb ->> 'object_path') as a1_path \gset
select tests.check(:'a1_path' ~ ('^' || :'a1' || '/[0-9a-f]{32}\.jpg$'), 'server chooses an unguessable path');
select tests.check((public.complete_profile_photo_upload(:'a1') ->> 'outcome') = 'upload_missing', 'cannot complete before the file exists');
select tests.expect_error(format($$insert into storage.objects (bucket_id, name, owner_id) values ('profile-photos', '%s/%s.jpg', auth.uid())$$,
  :'a1', md5('other')), 'row-level security', 'uploads only go to the reserved path');
select tests.become('authenticated', :bob);
select tests.expect_error(format($$insert into storage.objects (bucket_id, name, owner_id) values ('profile-photos', '%s', auth.uid())$$,
  :'a1_path'), 'row-level security', 'nobody else can fill your upload slot');
select tests.check((public.complete_profile_photo_upload(:'a1') ->> 'outcome') = 'not_found', 'nobody else can complete your upload');
select tests.become('authenticated', :alice);
insert into storage.objects (bucket_id, name, owner_id) values ('profile-photos', :'a1_path', auth.uid()::text);
select tests.check((public.complete_profile_photo_upload(:'a1') ->> 'outcome') = 'added', 'owner completes the upload');
select tests.check((select status = 'in_review' and is_primary and "position" = 1 from public.my_profile_photos()),
  'the first photo is primary and in review');

-- ---------------------------------------------------------------- nothing is writable directly
select tests.expect_error('select * from private.profile_photos', 'permission denied', 'photo records are private');
select tests.expect_error($$update private.media_assets set moderation_state = 'approved'$$, 'permission denied', 'users cannot approve themselves');
select tests.expect_error('update private.profile_photos set user_id = auth.uid()', 'permission denied', 'users cannot change ownership');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a1'), 'not_authorized',
  'users cannot use the moderation function');
select tests.become('authenticated', :alice, '{"role": "service_role"}');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a1'), 'not_authorized',
  'a service_role claim without the service_role database role is refused');
select tests.expect_error(format($$select public.record_profile_photo_fingerprints('%s', '%s', '%s')$$, :'a1', repeat('a', 64), repeat('1', 64)),
  'permission denied', 'users cannot write duplicate-detection fingerprints');
select tests.check((select count(*) = 0 from information_schema.routines where routine_schema = 'public'
  and routine_name = 'my_profile_photos' and routine_definition ~ 'sha256|perceptual|reason'), 'own-photo listing exposes no moderation metadata');

-- ---------------------------------------------------------------- unapproved photos are not served
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice)), 'unapproved photos are not listed for others');
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'profile-photos'), 'unapproved photos cannot be read or signed by others');
select tests.become('authenticated', :alice);
select tests.check((select count(*) = 1 from storage.objects where bucket_id = 'profile-photos'), 'owners can view their own pending photo');

-- ---------------------------------------------------------------- approval
select tests.approve(:'a1');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 1 from public.get_profile_photos(:alice)), 'approved photos of eligible users are listed');
select tests.check((select count(*) = 1 from storage.objects where bucket_id = 'profile-photos'), 'approved photos can be signed for eligible viewers');
select tests.become('authenticated', :alice);
select tests.check((select status = 'live' from public.my_profile_photos()), 'owner sees the photo as live');
select tests.upload_photo(:carol) as c1 \gset
select tests.become('authenticated', :mod, :mod_claims);
select public.moderate_profile_photo(:'c1', 'approve', 'fine');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.moderation_actions where action = 'photo_approve' and moderator_id = :mod),
  'moderator photo decisions are audited');

-- ---------------------------------------------------------------- ineligible viewers and owners
select tests.become('authenticated', :dave);
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice)), 'unverified viewers see nothing');
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'profile-photos'), 'unverified viewers cannot sign photos');
select tests.become('authenticated', :mod, :mod_claims);
select public.moderate_user(:carol, 'restrict', 'test');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.get_profile_photos(:carol)), 'restricted accounts'' photos are not served');
select tests.check(public.resolve_public_media(:'c1') is null, 'restricted accounts'' photos do not resolve either');
select tests.become('authenticated', :carol);
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice)), 'restricted users cannot see others'' photos');
select tests.check((public.begin_profile_photo_upload() ->> 'outcome') = 'not_allowed', 'restricted users cannot upload');
select tests.become_admin();
update private.accounts set manual_review_required = true where user_id = :alice;
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice)), 'accounts under review are not served');
select tests.become_admin();
update private.accounts set manual_review_required = false where user_id = :alice;

-- ---------------------------------------------------------------- blocks
select tests.become('authenticated', :alice);
select public.block_user(:bob);
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice)), 'a blocked user cannot list the blocker''s photos');
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'profile-photos'), 'a blocked user cannot sign them directly');
select tests.become('authenticated', :alice);
select tests.check((select count(*) = 0 from public.get_profile_photos(:bob)), 'and the blocker cannot see the blocked user''s photos');
select public.unblock_user(:bob);

-- ---------------------------------------------------------------- ordering, primary, delete
select tests.upload_photo(:bob) as b1 \gset
select tests.upload_photo(:bob) as b2 \gset
select tests.upload_photo(:bob) as b3 \gset
select tests.become('authenticated', :bob);
select tests.check((select array_agg(photo_id order by "position") = array[:'b1', :'b2', :'b3']::uuid[] from public.my_profile_photos()),
  'photos keep upload order');
select public.reorder_profile_photos(array[:'b3', :'b1', :'b2']::uuid[]);
select tests.check((select array_agg(photo_id order by "position") = array[:'b3', :'b1', :'b2']::uuid[] from public.my_profile_photos()),
  'owner can reorder');
select tests.expect_error(format($$select public.reorder_profile_photos(array['%s', '%s', '%s']::uuid[])$$, :'b3', :'b1', :'a1'),
  'exactly your current photos', 'reorder cannot include other users'' photos');
select public.set_primary_profile_photo(:'b2');
select tests.check((select count(*) = 1 and bool_and(photo_id = :'b2') from public.my_profile_photos() where is_primary), 'owner chooses the primary');
select tests.expect_error(format($$select public.set_primary_profile_photo('%s')$$, :'a1'), 'photo not found', 'cannot make another user''s photo primary');
select tests.check((public.delete_profile_photo(:'a1') ->> 'outcome') = 'not_found', 'cannot delete another user''s photo');
select tests.check((public.delete_profile_photo(:'b2') ->> 'outcome') = 'removed', 'owner can delete');
select tests.check((select count(*) = 2 and count(*) filter (where is_primary) = 1
  and array_agg("position" order by "position") = array[1, 2] from public.my_profile_photos()),
  'deleting the primary keeps exactly one primary and closes gaps');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.media_deletion_queue where object_path like :'b2' || '/%'), 'deleted files are queued for removal');
select tests.expect_error(format($$update private.profile_photos set user_id = '%s' where id = '%s'$$, :alice, :'b1'), 'immutable',
  'ownership is immutable even for admins');
begin;
set constraints all immediate;
select tests.expect_error(format($$update private.profile_photos set is_primary = false where user_id = '%s'$$, :bob),
  'exactly one primary', 'photos can never be left without a primary');
rollback;
select tests.expect_error(format($$update private.profile_photos set is_primary = true where user_id = '%s'$$, :bob),
  'profile_photos_one_primary_idx', 'there can never be two primaries');

-- ---------------------------------------------------------------- limits and change review
select tests.check((select count(*) filter (where (r ->> 'outcome') = 'ready') = 4
  from (select tests.become('authenticated', :bob), public.begin_profile_photo_upload() r from generate_series(1, 6)) x),
  'photo count is limited to 6 per profile');
select tests.become_admin();
select tests.check((select count(*) >= 1 from private.abuse_signals where user_id = :bob and signal_type = 'photo_replacement'),
  'a burst of new photos after verification is flagged for review');
select tests.check((select count(*) >= 3 from private.profile_change_events where user_id = :bob and change_kind = 'photo'),
  'photo changes count as significant profile changes');

-- ---------------------------------------------------------------- duplicates
select tests.become('service_role', null);
select public.record_profile_photo_fingerprints(:'a1', repeat('ab', 32), repeat('10', 32));
select tests.check(public.record_profile_photo_fingerprints(:'b1', repeat('ab', 32), repeat('10', 32)) = 1,
  'an exact copy of another account''s photo is detected');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.abuse_signals where user_id = :bob and signal_type = 'reused_public_image'),
  'reuse creates a review signal');
select tests.check((select status = 'active' from private.accounts where user_id = :bob), 'duplicates never ban automatically');
select tests.become('authenticated', :bob);
select tests.expect_error('delete from private.abuse_signals', 'permission denied', 'users cannot remove duplicate signals');
select tests.expect_error('update private.media_assets set sha256 = null', 'permission denied', 'users cannot alter fingerprints');
select tests.become_admin();
select tests.expect_error(format($$update private.media_assets set sha256 = '%s' where id = '%s'$$, repeat('cd', 32), :'b1'),
  'immutable', 'fingerprints cannot be changed once recorded');

-- ---------------------------------------------------------------- child safety
select tests.become('authenticated', :mod, :mod_claims);
select public.flag_media_for_child_safety(:'a1', 'suspected_csam') as cs_case \gset
select tests.become_admin();
select tests.check((select moderation_state = 'quarantined' from private.media_assets where id = :'a1'), 'flagged photo is quarantined');
select tests.check((select legal_hold and media_asset_id = :'a1' from private.child_safety_cases where id = :'cs_case'), 'a case with legal hold is attached');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice)), 'quarantined photos are not served');
select tests.check(public.resolve_public_media(:'a1') is null, 'quarantined photos do not resolve');
select tests.become('authenticated', :alice);
select tests.check((select status = 'in_review' and object_path is null from public.my_profile_photos() where photo_id = :'a1'),
  'the owner sees only "in review", never the case');
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'profile-photos'), 'the owner cannot read a quarantined photo');
select tests.check((public.delete_profile_photo(:'a1') ->> 'outcome') = 'under_review', 'held photos cannot be deleted (evidence is preserved)');
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a1'), 'not available',
  'moderators cannot approve a quarantined photo');
select tests.expect_error(format($$select public.child_safety_access_evidence('%s')$$, :'cs_case'), 'not_authorized',
  'ordinary moderators cannot access the evidence');

-- ---------------------------------------------------------------- verification media stays separate
select tests.become('authenticated', :erin);
select (public.start_verification_session() ->> 'session_id') as v_session \gset
select :'v_session' || '/' || md5('selfie') || '.jpg' as v_path \gset
insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', :'v_path', auth.uid()::text);
select tests.check((select count(*) = 0 from storage.objects where name = :'v_path'), 'verification photos cannot be read back or copied');
select tests.check((public.complete_profile_photo_upload(:'v_session') ->> 'outcome') = 'not_found',
  'a verification session cannot be turned into a profile photo');
select tests.expect_error(format($$insert into storage.objects (bucket_id, name, owner_id) values ('profile-photos', '%s', auth.uid())$$, :'v_path'),
  'row-level security', 'verification paths cannot be written into the profile photo bucket');
select tests.become_admin();
select tests.check((select count(*) = 0 from private.media_assets m join private.verification_sessions s on s.media_object_path = m.object_path),
  'no media asset ever points at verification evidence');
