-- Photo processing pipeline: worker API, validation, fingerprints,
-- provider results, retries, moderator functions, storage clean-up.
-- Synthetic fixtures only: storage rows without image data, made-up
-- hashes and fake provider results. No real CSAM hashes or images.

\set alice '''11111111-1111-1111-1111-111111111111'''
\set bob '''22222222-2222-2222-2222-222222222222'''
\set carol '''33333333-3333-3333-3333-333333333333'''
\set dave '''44444444-4444-4444-4444-444444444444'''
\set erin '''55555555-5555-5555-5555-555555555555'''
\set mod '''99999999-9999-9999-9999-999999999999'''
\set reviewer '''88888888-8888-8888-8888-888888888888'''
\set mod_claims '''{"app_metadata": {"role": "moderator"}, "aal": "aal2"}'''
\set reviewer_claims '''{"app_metadata": {"role": "child_safety_reviewer"}, "aal": "aal2"}'''
\set ok_validation '''{"ok": true, "width": 1200, "height": 1600, "bytes": 1000}'''

select tests.make_eligible(:alice, 'Alice');
select tests.make_eligible(:bob, 'Bob');
select tests.make_eligible(:carol, 'Carol');
insert into auth.users (id, email) values (:dave, 'dave@example.com'), (:reviewer, 'reviewer@example.com');
insert into auth.users (id, email, email_confirmed_at) values (:erin, 'erin@example.com', now());
insert into public.profiles (id, display_name, birth_date, location_city, location_state_or_region,
  gender, community_identity, dating_preference)
values (:erin, 'Erin', '1992-01-01', 'Salem', 'MA', 'agender', 'normie', 'normie_seeking_goth');

-- Synthetic fingerprints: distinct per label, deterministic.
create function tests.fp(p_label text) returns jsonb language sql security definer as $$
  select jsonb_build_object(
    'sha256', encode(extensions.digest(p_label, 'sha256'), 'hex'),
    'perceptual_hash', (select string_agg(case when get_bit(extensions.digest(p_label, 'sha256'), i) = 1 then '1' else '0' end, '')
                        from generate_series(0, 63) i))
$$;
create function tests.result(p_label text, p_cs text, p_mod text) returns jsonb language sql as $$
  select jsonb_build_object(
    'validation', '{"ok": true, "width": 1200, "height": 1600, "bytes": 1000}'::jsonb,
    'fingerprints', tests.fp(p_label),
    'child_safety', jsonb_build_object('result', p_cs),
    'moderation', jsonb_build_object('result', p_mod, 'categories', '["synthetic_category"]'::jsonb))
$$;

-- ---------------------------------------------------------------- entering the pipeline
select tests.upload_photo(:alice) as a1 \gset
select tests.check((select stage = 'uploaded' and attempts = 0 from private.photo_processing where photo_id = :'a1'),
  'a completed upload enters the pipeline as "uploaded"');
select tests.check(private.photo_pipeline_state(:'a1') = 'uploaded', 'internal state is uploaded');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice)), 'unprocessed photos are not visible');
select tests.become('authenticated', :alice);
select tests.check((select status = 'in_review' from public.my_profile_photos() where photo_id = :'a1'), 'owner sees "in review"');

-- ---------------------------------------------------------------- nobody but the worker
select tests.expect_error('select * from public.pipeline_claim_photos(10)', 'permission denied', 'users cannot claim photos');
select tests.expect_error(format($$select public.pipeline_submit_result('%s', 1, '{}')$$, :'a1'), 'permission denied',
  'users cannot submit processing results');
select tests.expect_error(format($$select public.pipeline_report_failure('%s', 1, 'x')$$, :'a1'), 'permission denied',
  'users cannot report failures');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a1'), 'not_authorized',
  'users cannot approve their own photo');
select tests.expect_error(format($$select public.record_profile_photo_fingerprints('%s', '%s', '%s')$$, :'a1', repeat('a', 64), repeat('0', 64)),
  'permission denied', 'users cannot provide fingerprints');
select tests.expect_error(format($$select public.report_child_safety_media_match('%s', 'suspected_csam', 'x')$$, :'a1'),
  'permission denied', 'users cannot forge child-safety provider results');
select tests.expect_error('select * from public.cleanup_claim_deletions(10)', 'permission denied', 'users cannot run clean-up');
select tests.become('authenticated', :alice, '{"role": "service_role"}');
select tests.expect_error(format($$select public.pipeline_submit_result('%s', 1, '{}')$$, :'a1'), 'permission denied',
  'a forged service_role claim cannot submit results');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a1'), 'not_authorized',
  'a forged service_role claim cannot approve');
select tests.become_admin();

-- ---------------------------------------------------------------- happy path + idempotency
select tests.submit_raw(:'a1', tests.result('alice-1', 'clear', 'approve')) as r \gset
select tests.check((:'r'::jsonb ->> 'outcome') = 'approved', 'a clear photo is approved');
select tests.become('service_role', null);
select tests.check((public.pipeline_submit_result(:'a1', (:'r'::jsonb ->> 'attempt')::int, tests.result('alice-1', 'clear', 'approve')) ->> 'outcome') = 'stale',
  'submitting the same result again is ignored');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.photo_processing_events where photo_id = :'a1' and event_type = 'approved'),
  'no duplicate approval events');
select tests.check((select count(*) = 1 from private.photo_processing_events where photo_id = :'a1' and event_type = 'result_ignored'),
  'the ignored retry is audited');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 1 from public.get_profile_photos(:alice)), 'approved photos are visible to eligible viewers');

-- ---------------------------------------------------------------- validation
select tests.upload_photo(:bob) as b_bad \gset
select tests.check((tests.submit_raw(:'b_bad', '{"validation": {"ok": false, "error": "not_jpeg"}}') ->> 'outcome') = 'rejected',
  'a non-JPEG is rejected');
select tests.check((select validation_error = 'not_jpeg' and validated_at is null from private.photo_processing where photo_id = :'b_bad'),
  'the validation error is recorded internally');
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'b_bad'), 'not passed processing',
  'an invalid file can never be approved, even by a moderator');
select tests.become_admin();

select tests.upload_photo(:bob) as b_mismatch \gset
select tests.check((tests.submit_raw(:'b_mismatch', jsonb_build_object(
    'validation', '{"ok": true, "width": 1200, "height": 1600, "bytes": 999}'::jsonb,
    'fingerprints', tests.fp('bob-mismatch'), 'child_safety', '{"result": "clear"}'::jsonb,
    'moderation', '{"result": "approve"}'::jsonb)) ->> 'outcome') = 'rejected',
  'a result that does not match the stored object is rejected');
select tests.upload_photo(:bob) as b_small \gset
select tests.check((tests.submit_raw(:'b_small', jsonb_build_object(
    'validation', '{"ok": true, "width": 50, "height": 50, "bytes": 1000}'::jsonb,
    'fingerprints', tests.fp('bob-small'), 'child_safety', '{"result": "clear"}'::jsonb,
    'moderation', '{"result": "approve"}'::jsonb)) ->> 'outcome') = 'rejected',
  'tiny images are rejected');
select tests.upload_photo(:bob, 0) as b_empty \gset
select tests.check((tests.submit_raw(:'b_empty', jsonb_build_object(
    'validation', '{"ok": true, "width": 1200, "height": 1600, "bytes": 0}'::jsonb,
    'fingerprints', tests.fp('bob-empty'), 'child_safety', '{"result": "clear"}'::jsonb,
    'moderation', '{"result": "approve"}'::jsonb)) ->> 'outcome') = 'rejected',
  'zero-byte uploads are rejected');
select tests.become('authenticated', :bob);
select tests.check((select bool_and(status = 'not_approved') from public.my_profile_photos()
  where photo_id in (:'b_bad', :'b_mismatch', :'b_small', :'b_empty')), 'owner sees only "not approved"');
select tests.become('authenticated', :alice);
select tests.check((select count(*) = 0 from public.get_profile_photos(:bob)), 'rejected photos are never visible');
select tests.become('authenticated', :bob);
select tests.check((select count(*) filter (where (public.delete_profile_photo(id) ->> 'outcome') = 'removed') = 4
  from unnest(array[:'b_bad', :'b_mismatch', :'b_small', :'b_empty']::uuid[]) id), 'owners can delete rejected photos');
select tests.become_admin();

-- ---------------------------------------------------------------- fail closed
select tests.upload_photo(:bob) as b_nofp \gset
select tests.check((tests.submit_raw(:'b_nofp', jsonb_build_object('validation', :ok_validation::jsonb)) ->> 'outcome') = 'retry_scheduled',
  'missing fingerprints never approve');
select tests.upload_photo(:bob) as b_noprov \gset
select tests.check((tests.submit_raw(:'b_noprov', jsonb_build_object('validation', :ok_validation::jsonb, 'fingerprints', tests.fp('bob-noprov'))) ->> 'outcome') = 'manual_review',
  'without provider results the photo waits for a human (no provider configured)');
select tests.check((select review_reasons @> array['child_safety_unavailable', 'moderation_unavailable'] from private.photo_processing where photo_id = :'b_noprov'),
  'the reason is recorded internally');

-- ---------------------------------------------------------------- provider failure and retry
select tests.upload_photo(:bob) as b_retry \gset
select tests.check((tests.submit_raw(:'b_retry', tests.result('bob-retry', 'provider_error', 'approve')) ->> 'outcome') = 'retry_scheduled',
  'a child-safety provider error schedules a retry');
select tests.check((select stage = 'processing_failed' and next_attempt_at > now() from private.photo_processing where photo_id = :'b_retry'),
  'the retry waits (backoff)');
select tests.check((tests.submit_raw(:'b_retry', tests.result('bob-retry', 'clear', 'approve')) ->> 'outcome') = 'not_claimed',
  'it is not retried before the backoff');
select tests.become('authenticated', :alice);
select tests.check((select count(*) = 0 from public.get_profile_photos(:bob)), 'failed photos stay invisible');
select tests.become_admin();
update private.photo_processing set next_attempt_at = now() where photo_id = :'b_retry';
select tests.check((tests.submit_raw(:'b_retry', tests.result('bob-retry', 'clear', 'moderation_timeout_then_ok')) ->> 'outcome') = 'manual_review',
  'an unknown moderation result fails closed to manual review');
select tests.check((select count(*) = 1 from private.media_assets where id = :'b_retry' and sha256 is not null),
  'fingerprints are recorded once across retries');

select tests.upload_photo(:bob) as b_timeout \gset
select tests.become('service_role', null);
select attempt as t_attempt from public.pipeline_claim_photos(50) where photo_id = :'b_timeout' \gset
select tests.check((public.pipeline_report_failure(:'b_timeout', :t_attempt, 'provider_timeout') ->> 'outcome') = 'retry_scheduled',
  'a provider timeout schedules a retry');
select tests.check((public.pipeline_report_failure(:'b_timeout', :t_attempt, 'provider_timeout') ->> 'outcome') = 'stale',
  'reporting the same failure twice is ignored');
select tests.become_admin();
update private.photo_processing set attempts = 4, next_attempt_at = now() where photo_id = :'b_timeout';
select tests.check((tests.submit_raw(:'b_timeout', tests.result('bob-timeout', 'clear', 'provider_error')) ->> 'outcome') = 'processing_failed',
  'after the last attempt processing stops (no endless retries)');
select tests.check((tests.submit_raw(:'b_timeout', tests.result('bob-timeout', 'clear', 'approve')) ->> 'outcome') = 'not_claimed',
  'an exhausted photo is not claimed again');
select tests.become('authenticated', :mod, :mod_claims);
select tests.check((select count(*) = 1 from public.moderator_photos_awaiting_review() where photo_id = :'b_timeout'),
  'exhausted photos appear in the moderator queue');
select public.moderator_retry_photo_processing(:'b_timeout');
select tests.become_admin();
select tests.check((tests.submit_raw(:'b_timeout', tests.result('bob-timeout', 'clear', 'approve')) ->> 'outcome') = 'approved',
  'a moderator retry lets processing succeed');

-- ---------------------------------------------------------------- duplicates
select tests.upload_photo(:carol) as c_dup \gset
select tests.check((tests.submit_raw(:'c_dup', tests.result('alice-1', 'clear', 'provider_error')) ->> 'outcome') = 'retry_scheduled',
  'setup: a duplicate photo fails once after fingerprinting');
select tests.check((select count(*) = 1 from private.abuse_signals where user_id = :carol and signal_type = 'reused_public_image'),
  'an exact duplicate of another account''s photo creates a review signal');
update private.photo_processing set next_attempt_at = now() where photo_id = :'c_dup';
select tests.check((tests.submit_raw(:'c_dup', tests.result('alice-1', 'clear', 'approve')) ->> 'outcome') = 'manual_review',
  'the duplicate goes to manual review even when moderation approves');
select tests.check((select count(*) = 1 from private.abuse_signals where user_id = :carol and signal_type = 'reused_public_image'),
  'retries do not duplicate the signal');
select tests.check((select review_reasons = array['duplicate_exact'] from private.photo_processing where photo_id = :'c_dup'),
  'the duplicate reason survives the retry');
select tests.check((select status = 'active' from private.accounts where user_id = :carol), 'a duplicate never bans');

-- near duplicate: flip one bit of alice's perceptual hash, new sha
select tests.upload_photo(:carol) as c_near \gset
select tests.check((tests.submit_raw(:'c_near', jsonb_build_object(
    'validation', :ok_validation::jsonb,
    'fingerprints', jsonb_build_object('sha256', encode(extensions.digest('carol-near', 'sha256'), 'hex'),
      'perceptual_hash', overlay((tests.fp('alice-1') ->> 'perceptual_hash') placing
        case when substr(tests.fp('alice-1') ->> 'perceptual_hash', 1, 1) = '1' then '0' else '1' end from 1 for 1)),
    'child_safety', '{"result": "clear"}'::jsonb, 'moderation', '{"result": "approve"}'::jsonb)) ->> 'outcome') = 'manual_review',
  'a near duplicate goes to manual review');
select tests.check((select review_reasons = array['duplicate_near'] from private.photo_processing where photo_id = :'c_near'),
  'recorded as a near duplicate');
select tests.become('authenticated', :carol);
select tests.expect_error('delete from private.abuse_signals', 'permission denied', 'users cannot remove duplicate signals');
select tests.expect_error('update private.media_assets set sha256 = null', 'permission denied', 'users cannot forge or clear fingerprints');
select tests.become_admin();

-- ---------------------------------------------------------------- moderation outcomes
select tests.become('authenticated', :bob);
select public.delete_profile_photo(id) from unnest(array[:'b_nofp', :'b_retry']::uuid[]) id;
select tests.become_admin();
select tests.upload_photo(:bob) as b_rej \gset
select tests.check((tests.submit_raw(:'b_rej', tests.result('bob-rej', 'clear', 'reject')) ->> 'outcome') = 'rejected',
  'a moderation rejection rejects the photo');
select tests.check((select count(*) >= 1 from private.abuse_signals where user_id = :bob and signal_type = 'rejected_profile_photo'),
  'a rejected photo adds a low review signal');
select tests.upload_photo(:bob) as b_man \gset
select tests.check((tests.submit_raw(:'b_man', tests.result('bob-man', 'clear', 'manual_review')) ->> 'outcome') = 'manual_review',
  'moderation can ask for a human');
select tests.upload_photo(:bob) as b_csman \gset
select tests.check((tests.submit_raw(:'b_csman', tests.result('bob-csman', 'manual_review_required', 'approve')) ->> 'outcome') = 'manual_review',
  'child-safety "manual review required" is never auto-approved');
select tests.upload_photo(:bob) as b_pending \gset
select tests.check((tests.submit_raw(:'b_pending', tests.result('bob-pending', 'pending', 'approve')) ->> 'outcome') = 'awaiting_provider',
  'an asynchronous provider puts the photo in "awaiting provider"');
select tests.become('authenticated', :bob);
select tests.check((select bool_and(status = 'in_review') from public.my_profile_photos() where photo_id in (:'b_man', :'b_csman', :'b_pending')),
  'all of those look like "in review" to the owner');
select tests.check((select count(*) = 0 from pg_proc where proname in ('my_profile_photos', 'get_profile_photos')
  and pg_get_function_result(oid) ~* '(reason|categor|sha|hash|provider|risk|child)'),
  'user-facing photo functions return no internal moderation fields');
select tests.expect_error('select * from public.moderator_photos_awaiting_review()', 'not_authorized', 'users cannot read the review queue');
select tests.expect_error(format($$select public.moderator_photo_review_context('%s')$$, :'b_man'), 'not_authorized',
  'users cannot use the verification comparison hook');

-- ---------------------------------------------------------------- moderator support
select tests.become('authenticated', :mod, :mod_claims);
select tests.check((select count(*) >= 3 from public.moderator_photos_awaiting_review() where photo_id in (:'b_man', :'b_csman', :'b_noprov')),
  'photos needing a human are listed for moderators');
select public.moderate_profile_photo(:'b_man', 'approve', 'looks fine');
select tests.become('authenticated', :alice);
select tests.check((select count(*) = 1 from public.get_profile_photos(:bob) where photo_id = :'b_man'), 'moderator approval publishes the photo');
select tests.become('authenticated', :mod, :mod_claims);
select public.moderate_profile_photo(:'b_noprov', 'reject', 'not a person');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.photo_processing_events where photo_id = :'b_man' and event_type = 'approved' and actor_type = 'moderator' and actor_id = :mod),
  'moderator decisions are audited with the moderator id');

-- verification comparison hook (moderator only, audited)
insert into private.verification_sessions (id, user_id, status, challenge_type, attempt_number, created_at, expires_at, reviewed_at, media_object_path)
values ('dddddddd-0000-0000-0000-000000000001', :bob, 'approved', 'blink', 1, now() - interval '1 day', now() - interval '1 day' + interval '10 minutes',
        now() - interval '1 day', 'dddddddd-0000-0000-0000-000000000001/' || md5('bob-selfie') || '.jpg');
select tests.become('authenticated', :mod, :mod_claims);
select tests.check((public.moderator_photo_review_context(:'b_csman') -> 'verification_photo' ->> 'bucket_id') = 'verification-media',
  'moderators can compare a photo with the verification photo by eye');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.photo_processing_events where photo_id = :'b_csman' and event_type = 'verification_compare_accessed' and actor_id = :mod),
  'every comparison access is audited');

-- ---------------------------------------------------------------- child safety
select tests.upload_photo(:carol) as c_cs \gset
select tests.upload_photo(:carol) as c_other \gset
select tests.submit_raw(:'c_cs', tests.result('carol-cs', 'possible_match', 'approve')) as cs_r \gset
select tests.check((:'cs_r'::jsonb ->> 'outcome') = 'quarantined', 'a possible child-safety match quarantines the photo');
select tests.check((select category = 'suspected_csam' and legal_hold from private.child_safety_cases where media_asset_id = :'c_cs'),
  'a child-safety case with legal hold is opened');
select tests.check(private.has_active_safety_hold(:carol), 'the account is held');
select tests.become('service_role', null);
select tests.check((public.pipeline_submit_result(:'c_cs', (:'cs_r'::jsonb ->> 'attempt')::int, tests.result('carol-cs', 'possible_match', 'approve')) ->> 'outcome') = 'stale',
  'a repeated child-safety result is ignored');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.child_safety_cases where media_asset_id = :'c_cs'), 'no duplicate cases on retry');
select tests.check((tests.submit_raw(:'c_other', tests.result('carol-other', 'clear', 'approve')) ->> 'outcome') = 'not_claimed',
  'nothing else of a held account is processed');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.get_profile_photos(:carol)), 'quarantined photos and held accounts are never visible');
select tests.become('authenticated', :carol);
select tests.check((select status = 'in_review' and object_path is null from public.my_profile_photos() where photo_id = :'c_cs'),
  'the owner sees only "in review"');
select tests.become('authenticated', :mod, :mod_claims);
select tests.check((select count(*) = 0 from public.moderator_photos_awaiting_review() where photo_id = :'c_cs'),
  'child-safety photos are not in the ordinary moderator queue');
select tests.expect_error(format($$select public.moderator_photo_review_context('%s')$$, :'c_cs'), 'child-safety reviewers',
  'ordinary moderators cannot open child-safety photos');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'c_cs'), 'not available',
  'ordinary moderators cannot approve them');
select tests.become_admin();
select id as c_case from private.child_safety_cases where media_asset_id = :'c_cs' \gset
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.child_safety_access_evidence('%s')$$, :'c_case'),
  'not_authorized', 'ordinary moderators cannot reach the evidence');
select tests.become('authenticated', :reviewer, :reviewer_claims);
select tests.check((public.child_safety_access_evidence(:'c_case') ->> 'bucket_id') = 'profile-photos',
  'only an MFA child-safety reviewer can locate it');
select tests.become('authenticated', :carol);
select tests.expect_error('select * from private.child_safety_cases', 'permission denied', 'users cannot see cases');

select tests.become_admin();
select tests.make_eligible('66666666-6666-6666-6666-666666666666', 'Frank');
select tests.upload_photo('66666666-6666-6666-6666-666666666666') as b_hash \gset
select tests.check((tests.submit_raw(:'b_hash', tests.result('bob-hash', 'confirmed_known_hash_match', 'approve')) ->> 'outcome') = 'quarantined',
  'a confirmed known-hash match quarantines the photo');
select tests.check((select category = 'known_csam_hash_match' and source = 'hash_match_provider' and legal_hold
  from private.child_safety_cases where media_asset_id = :'b_hash'), 'on the critical, preserved path');

-- ---------------------------------------------------------------- storage clean-up
select tests.become_admin();
insert into private.media_deletion_queue (bucket_id, object_path, media_asset_id)
select bucket_id, object_path, id from private.media_assets where id = :'c_cs';
select object_path as c_cs_path from private.media_assets where id = :'c_cs' \gset
select tests.become('service_role', null);
select tests.check((select count(*) = 0 from public.cleanup_claim_deletions(50) c where c.object_path = :'c_cs_path'),
  'legal-hold media is never handed out for deletion');
select tests.become_admin();
select tests.check((select status = 'skipped_hold' from private.media_deletion_queue where media_asset_id = :'c_cs'), 'it is marked as skipped for the hold');

select tests.become('authenticated', :alice);
select public.delete_profile_photo(:'a1');
select tests.become_admin();
select tests.check((select status = 'pending' from private.media_deletion_queue where media_asset_id = :'a1'), 'a deleted normal photo is queued');
select tests.become('service_role', null);
select queue_id as a1_queue from public.cleanup_claim_deletions(50) c where c.object_path like :'a1' || '/%' \gset
select tests.check(public.cleanup_confirm_deletable(:a1_queue), 'the worker re-confirms before deleting');
select tests.check(public.cleanup_mark_result(:a1_queue, true) = 'deleted', 'successful deletion is recorded');
select tests.check(public.cleanup_mark_result(:a1_queue, true) = 'ignored', 'recording it again is a no-op');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.photo_processing_events where photo_id = :'a1' and event_type = 'deleted'),
  'the deletion is audited');

update private.media_assets set decided_at = now() - interval '31 days' where id = :'b_rej';
select tests.become('authenticated', :erin);
select (public.begin_profile_photo_upload() ->> 'asset_id') as abandoned \gset
select tests.become_admin();
update private.media_assets set created_at = now() - interval '1 hour' where id = :'abandoned';
select tests.become('service_role', null);
select tests.check(public.cleanup_enqueue_expired() >= 2, 'expired rejected photos and abandoned uploads are queued');
select tests.check(public.cleanup_enqueue_expired() = 0, 'enqueueing is idempotent');
select tests.become_admin();
select tests.check((select moderation_state = 'removed' from private.media_assets where id = :'abandoned'), 'abandoned upload slots are closed');
select tests.check((select count(*) = 1 from private.media_deletion_queue where media_asset_id = :'b_rej'), 'the old rejected photo is queued once');

-- ---------------------------------------------------------------- verification media stays out
select tests.become('authenticated', :erin);
select (public.start_verification_session() ->> 'session_id') as v_session \gset
select :'v_session' || '/' || md5('erin-selfie') || '.jpg' as v_path \gset
insert into storage.objects (bucket_id, name, owner_id, metadata)
values ('verification-media', :'v_path', auth.uid()::text, '{"size": 1000, "mimetype": "image/jpeg"}');
select tests.become('service_role', null);
select tests.check((select count(*) = 0 from public.pipeline_claim_photos(50) c where c.bucket_id <> 'profile-photos' or c.object_path = :'v_path'),
  'verification media never enters the photo pipeline');
select tests.check((public.pipeline_submit_result(:'v_session', 1, tests.result('x', 'clear', 'approve')) ->> 'outcome') = 'not_found',
  'a verification session id is not a processable photo');
select tests.become_admin();

-- ---------------------------------------------------------------- viewers
select tests.become('authenticated', :alice);
select tests.check((select count(*) >= 1 from public.get_profile_photos(:bob)), 'setup: bob''s approved photos are visible before the block');
select public.block_user(:bob);
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice)), 'blocked viewers get nothing');
select tests.become('authenticated', :alice);
select tests.check((select count(*) = 0 from public.get_profile_photos(:bob)), 'blockers get nothing either');
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'profile-photos' and owner_id = :bob), 'and cannot sign URLs directly');
select public.unblock_user(:bob);
select tests.become('authenticated', :dave);
select tests.check((select count(*) = 0 from public.get_profile_photos(:bob)), 'ineligible viewers get nothing');
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'profile-photos'), 'ineligible viewers cannot sign URLs');
select tests.become_admin();
select tests.expect_error('update private.photo_processing_events set event_type = ''approved''', 'append-only', 'the processing audit log is append-only');
