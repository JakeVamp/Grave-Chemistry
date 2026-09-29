-- Moderator photo-review tool: access control (role + MFA), child-safety
-- separation, queue contents, stale items, notes and audit trail.
-- Synthetic fixtures only: storage rows without image data, made-up hashes
-- and fake provider results.

\set alice '''11111111-1111-1111-1111-111111111111'''
\set bob '''22222222-2222-2222-2222-222222222222'''
\set carol '''33333333-3333-3333-3333-333333333333'''
\set frank '''66666666-6666-6666-6666-666666666666'''
\set mod '''99999999-9999-9999-9999-999999999999'''
\set mod2 '''77777777-7777-7777-7777-777777777777'''
\set reviewer '''88888888-8888-8888-8888-888888888888'''
\set mod_claims '''{"app_metadata": {"role": "moderator"}, "aal": "aal2"}'''
\set mod_no_mfa '''{"app_metadata": {"role": "moderator"}, "aal": "aal1"}'''
\set forged_claims '''{"user_metadata": {"role": "moderator"}, "aal": "aal2"}'''
\set reviewer_claims '''{"app_metadata": {"role": "child_safety_reviewer"}, "aal": "aal2"}'''
\set dup_sha '''aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'''
\set dup_phash '''1010101010101010101010101010101010101010101010101010101010101010'''

select tests.make_eligible(:alice, 'Alice');
select tests.make_eligible(:bob, 'Bob');
select tests.make_eligible(:carol, 'Carol');
select tests.make_eligible(:frank, 'Frank');
insert into auth.users (id, email) values (:mod2, 'mod2@example.com'), (:reviewer, 'reviewer@example.com');

-- ---------------------------------------------------------------- fixtures
-- Alice: a live photo (the original of a duplicate), one waiting for a
-- moderator, one never processed.
select tests.upload_photo(:alice) as a_live \gset
select tests.check(tests.process_photo(:'a_live', 'clear', 'approve', :dup_sha, :dup_phash) = 'approved', 'setup: alice has a live photo');
select tests.upload_photo(:alice) as a_manual \gset
select tests.check(tests.process_photo(:'a_manual', 'clear', 'manual_review') = 'manual_review', 'setup: a photo waits for a moderator');
select tests.upload_photo(:alice) as a_ok \gset
select tests.check(tests.process_photo(:'a_ok', 'clear', 'manual_review') = 'manual_review', 'setup: another photo waits for a moderator');
select tests.upload_photo(:alice) as a_raw \gset

-- Bob: an exact duplicate of Alice's photo, a failed photo, two to decide.
select tests.upload_photo(:bob) as b_dup \gset
select tests.check(tests.process_photo(:'b_dup', 'clear', 'approve', :dup_sha, :dup_phash) = 'manual_review',
  'setup: a duplicate goes to manual review');
select tests.upload_photo(:bob) as b_fail \gset
update private.photo_processing set attempts = 4 where photo_id = :'b_fail';
select tests.check(tests.process_photo(:'b_fail', 'clear', 'provider_error') = 'processing_failed',
  'setup: a photo whose processing failed for good');
select tests.check((select validated_at is not null from private.photo_processing where photo_id = :'b_fail'),
  'setup: the failed photo had passed validation');
select tests.upload_photo(:bob) as b_rej \gset
select tests.check(tests.process_photo(:'b_rej', 'clear', 'manual_review') = 'manual_review', 'setup: photo to reject');
select tests.upload_photo(:bob) as b_rem \gset
select tests.check(tests.process_photo(:'b_rem', 'clear', 'manual_review') = 'manual_review', 'setup: photo to remove');

-- Carol: a possible child-safety match (case + quarantine + hold).
select tests.upload_photo(:carol) as c_cs \gset
select tests.check(tests.process_photo(:'c_cs', 'possible_match', 'approve') = 'quarantined', 'setup: a child-safety match');

-- Frank: a photo waiting for a moderator, then the account is held by a
-- child-safety case that has nothing to do with the photo.
select tests.upload_photo(:frank) as f_held \gset
select tests.check(tests.process_photo(:'f_held', 'clear', 'manual_review') = 'manual_review', 'setup: frank waits for review');
select private.open_child_safety_case(:frank, 'underage_user_concern', 'user_report', null, null, true);

-- An approved verification photo for Alice (path only; no image data).
insert into private.verification_sessions (id, user_id, status, challenge_type, attempt_number, created_at, expires_at, reviewed_at, media_object_path)
values ('dddddddd-0000-0000-0000-000000000001', :alice, 'approved', 'blink', 1, now() - interval '1 day',
        now() - interval '1 day' + interval '10 minutes', now() - interval '1 day',
        'dddddddd-0000-0000-0000-000000000001/' || md5('alice-selfie') || '.jpg');
select 'dddddddd-0000-0000-0000-000000000001/' || md5('alice-selfie') || '.jpg' as v_path \gset
insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', :'v_path', :alice);

-- ---------------------------------------------------------------- normal users
select tests.become('authenticated', :bob);
select tests.expect_error('select * from public.moderator_photo_review_queue()', 'not_authorized', 'users cannot read the review queue');
select tests.expect_error('select * from public.moderator_photos_awaiting_review()', 'not_authorized', 'users cannot read the old queue either');
select tests.expect_error(format($$select * from public.moderator_photo_review_item('%s')$$, :'a_manual'), 'not_authorized',
  'users cannot read review items');
select tests.expect_error(format($$select public.moderator_photo_review_context('%s')$$, :'a_manual'), 'not_authorized',
  'users cannot get photo locations for review');
select tests.expect_error(format($$select * from public.moderator_photo_notes('%s')$$, :'a_manual'), 'not_authorized',
  'users cannot read moderator notes');
select tests.expect_error(format($$select public.moderator_add_photo_note('%s', 'x')$$, :'a_manual'), 'not_authorized',
  'users cannot write moderator notes');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a_manual'), 'not_authorized',
  'users cannot approve');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'reject')$$, :'a_manual'), 'not_authorized',
  'users cannot reject');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'remove')$$, :'a_manual'), 'not_authorized',
  'users cannot remove');
select tests.expect_error(format($$select public.moderator_retry_photo_processing('%s')$$, :'b_fail'), 'not_authorized',
  'users cannot retry processing');
select tests.expect_error(format($$select public.moderate_user('%s', 'require_reverification', 'x')$$, :alice), 'not_authorized',
  'users cannot require re-verification');
select tests.expect_error(format($$select public.flag_media_for_child_safety('%s', 'suspected_csam')$$, :'a_manual'), 'not_authorized',
  'users cannot escalate to child safety');
select tests.expect_error('select * from private.moderator_notes', 'permission denied', 'users cannot read the notes table');
select tests.expect_error('select * from private.moderation_actions', 'permission denied', 'users cannot read the audit trail');

select tests.become('authenticated', :bob, :forged_claims);
select tests.expect_error('select * from public.moderator_photo_review_queue()', 'not_authorized',
  'a self-set role in user_metadata grants nothing');

select tests.become('anon', null);
select tests.expect_error('select * from public.moderator_photo_review_queue()', 'permission denied', 'signed-out callers cannot call it at all');

-- ---------------------------------------------------------------- moderator without MFA
select tests.become('authenticated', :mod, :mod_no_mfa);
select tests.expect_error('select * from public.moderator_photo_review_queue()', 'not_authorized', 'no MFA: no queue');
select tests.expect_error(format($$select * from public.moderator_photo_review_item('%s')$$, :'a_manual'), 'not_authorized', 'no MFA: no item');
select tests.expect_error(format($$select public.moderator_photo_review_context('%s')$$, :'a_manual'), 'not_authorized',
  'no MFA: no photo locations, so no signed URLs');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a_manual'), 'not_authorized', 'no MFA: cannot approve');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'reject')$$, :'a_manual'), 'not_authorized', 'no MFA: cannot reject');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'remove')$$, :'a_manual'), 'not_authorized', 'no MFA: cannot remove');
select tests.expect_error(format($$select public.moderator_retry_photo_processing('%s')$$, :'b_fail'), 'not_authorized', 'no MFA: cannot retry');
select tests.expect_error(format($$select public.moderator_add_photo_note('%s', 'x')$$, :'a_manual'), 'not_authorized', 'no MFA: cannot add notes');
select tests.expect_error(format($$select public.moderate_user('%s', 'require_reverification', 'x')$$, :alice), 'not_authorized',
  'no MFA: cannot require re-verification');
select tests.expect_error(format($$select public.flag_media_for_child_safety('%s', 'suspected_csam')$$, :'a_manual'), 'not_authorized',
  'no MFA: cannot escalate');
select tests.become_admin();
select tests.check((select count(*) = 0 from private.moderation_actions), 'refused calls leave no actions behind');
select tests.check((select moderation_state = 'pending_scan' from private.media_assets where id = :'a_manual'), 'and change nothing');

-- ---------------------------------------------------------------- queue contents
select tests.become('authenticated', :mod, :mod_claims);
select tests.check((select display_name = 'Alice' and age = date_part('year', age(current_date, date '1990-01-01'))::int
    and verification_status = 'verified' and review_state = 'awaiting_review' and can_approve and not can_retry
    and duplicate_match is null
  from public.moderator_photo_review_queue() where photo_id = :'a_manual'),
  'a waiting photo shows name, age, verification and that it can be approved');
select tests.check((select has_review_signals from public.moderator_photo_review_queue() where photo_id = :'a_manual'),
  'open review signals are flagged (four new photos after verification)');
select tests.become_admin();
update private.abuse_signals set review_status = 'dismissed' where user_id = :alice;
select tests.become('authenticated', :mod, :mod_claims);
select tests.check((select not has_review_signals from public.moderator_photo_review_queue() where photo_id = :'a_manual'),
  'an account without open signals shows none');
select tests.check((select duplicate_match = 'exact' and has_review_signals
  from public.moderator_photo_review_queue() where photo_id = :'b_dup'),
  'a duplicate shows as an exact match and the account has review signals');
select tests.check((select review_state = 'processing_failed' and can_retry and not can_approve
  from public.moderator_photo_review_queue() where photo_id = :'b_fail'),
  'a failed photo can be retried, not approved');
select tests.check((select bool_and(automated_checks_incomplete = false)
  from public.moderator_photo_review_queue() where photo_id in (:'a_manual', :'b_dup')),
  'photos with complete automated checks are marked as such');
select tests.check((select count(*) = 0 from public.moderator_photo_review_queue() q
  where row_to_json(q)::text like '%' || :'dup_sha' || '%' or row_to_json(q)::text like '%' || :'dup_phash' || '%'),
  'no raw hashes in the queue');
select tests.check((select count(*) = 0 from pg_proc where proname in ('moderator_photo_review_queue', 'moderator_photo_review_item', 'moderator_photo_notes')
  and pg_get_function_result(oid) ~* '(path|url|sha|hash|provider|categor|child|reason|bucket)'),
  'queue and item functions return no paths, hashes, provider or child-safety fields');
select tests.check((select count(*) = 0 from public.moderator_photo_review_queue() where photo_id = :'a_raw'),
  'photos still being processed are not queued');

-- ---------------------------------------------------------------- child-safety separation
select tests.check((select count(*) = 0 from public.moderator_photo_review_queue() where photo_id = :'c_cs'),
  'a child-safety case never appears in the moderator queue');
select tests.check((select count(*) = 0 from public.moderator_photos_awaiting_review() where photo_id = :'c_cs'),
  '...nor in the old queue function');
select tests.check((select count(*) = 0 from public.moderator_photo_review_queue() where owner_id = :frank),
  'photos of an account under a child-safety hold are hidden from the queue');
select tests.check((select count(*) = 0 from public.moderator_photos_awaiting_review() where owner_id = :frank),
  '...including the old queue function (fixed)');
select tests.check((select count(*) = 0 from public.moderator_photo_review_item(:'c_cs')), 'a child-safety photo cannot be opened as an item');
select tests.check((select count(*) = 0 from public.moderator_photo_review_item(:'f_held')), 'nor a photo of a held account');
select tests.check((select count(*) = 0 from public.moderator_photo_notes(:'c_cs')), 'no notes are returned for child-safety photos');
select tests.expect_error(format($$select public.moderator_photo_review_context('%s')$$, :'c_cs'), 'child-safety reviewers',
  'no photo locations (so no signed URLs) for child-safety photos');
select tests.expect_error(format($$select public.moderator_photo_review_context('%s')$$, :'f_held'), 'child-safety reviewers',
  'no photo locations for held accounts');
select tests.expect_error(format($$select public.moderator_add_photo_note('%s', 'x')$$, :'c_cs'), 'not available',
  'moderators cannot annotate child-safety photos');
select tests.expect_error(format($$select public.moderator_retry_photo_processing('%s')$$, :'c_cs'), 'not in a failed state',
  'moderators cannot restart child-safety photos');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'f_held'), 'child-safety review',
  'a held account''s photo cannot be approved');
select tests.become_admin();
select id as c_case from private.child_safety_cases where media_asset_id = :'c_cs' \gset
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.child_safety_access_evidence('%s')$$, :'c_case'), 'not_authorized',
  'ordinary moderators cannot fetch child-safety evidence');
select tests.become('authenticated', :reviewer, :reviewer_claims);
select tests.expect_error('select * from public.moderator_photo_review_queue()', 'not_authorized',
  'the child-safety reviewer role is separate from ordinary moderation');

-- ---------------------------------------------------------------- review context (for signed URLs)
select tests.become('authenticated', :mod, :mod_claims);
select public.moderator_photo_review_context(:'a_manual') as ctx \gset
select tests.check((:'ctx'::jsonb -> 'profile_photo' ->> 'bucket_id') = 'profile-photos'
  and (:'ctx'::jsonb -> 'verification_photo' ->> 'bucket_id') = 'verification-media',
  'a moderator with MFA gets both locations for side-by-side review');
select tests.check((:'ctx'::jsonb)::text !~* '(sha|hash|provider|categor|url)', 'the context has no hashes, provider data or URLs');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.moderation_actions
  where action = 'photo_review_opened' and media_asset_id = :'a_manual' and moderator_id = :mod and target_user_id = :alice),
  'opening the review context is audited (moderator, photo, user)');
select tests.check((select count(*) = 1 from private.photo_processing_events
  where photo_id = :'a_manual' and event_type = 'verification_compare_accessed' and actor_id = :mod),
  'and recorded in the photo history');

-- ---------------------------------------------------------------- verification media stays private
select tests.become('authenticated', :alice);
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'verification-media'),
  'the owner cannot read their verification photo');
select tests.check((select count(*) = 0 from public.my_profile_photos() where object_path = :'v_path'),
  'my_profile_photos never returns verification media');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'verification-media'),
  'other users cannot read verification photos');
select tests.check((select count(*) = 0 from public.get_profile_photos(:alice) where object_path = :'v_path'),
  'get_profile_photos never returns verification media');
select tests.check(not private.can_read_profile_photo_object(:'v_path'), 'profile-photo storage rules never admit a verification path');
select tests.become('authenticated', :mod, :mod_claims);
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'verification-media'),
  'moderators get no direct storage access; only the audited review path');
select tests.become_admin();
select object_path as a_manual_path from private.media_assets where id = :'a_manual' \gset
select tests.become('authenticated', :mod, :mod_claims);
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'profile-photos' and name = :'a_manual_path'),
  'moderators cannot read (or sign) pending photos directly either');

-- ---------------------------------------------------------------- approval gates
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'b_fail'), 'not awaiting a decision',
  'a photo whose processing failed cannot be approved, even though it passed validation');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a_raw'), 'not passed processing',
  'an unprocessed photo cannot be approved');
select public.moderate_profile_photo(:'a_ok', 'approve', null);
select tests.check((select count(*) = 0 from public.moderator_photo_review_queue() where photo_id = :'a_ok'),
  'an approved photo leaves the queue');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.moderation_actions
  where action = 'photo_approve' and media_asset_id = :'a_ok' and moderator_id = :mod and target_user_id = :alice),
  'approval is audited with photo, user and moderator');

-- ---------------------------------------------------------------- stale items
-- Moderator 1 has a_manual open; moderator 2 rejects it first.
select tests.become('authenticated', :mod2, :mod_claims);
select public.moderate_profile_photo(:'a_manual', 'reject', null);
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'a_manual'), 'not awaiting a decision',
  'a stale item cannot be approved after another moderator rejected it');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'reject')$$, :'a_manual'), 'not awaiting a decision',
  'or rejected a second time');
select tests.check((select review_state = 'decided' and not can_approve and not can_retry from public.moderator_photo_review_item(:'a_manual')),
  'refreshing the item shows it was already decided');
-- Moderator 2 retries b_fail while moderator 1 is looking at it.
select tests.become('authenticated', :mod2, :mod_claims);
select public.moderator_retry_photo_processing(:'b_fail');
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.moderator_retry_photo_processing('%s')$$, :'b_fail'), 'not in a failed state',
  'a second retry of the same item is refused');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'b_fail'), 'not awaiting a decision',
  'a photo being re-processed cannot be approved');
select tests.check((select review_state = 'processing' from public.moderator_photo_review_item(:'b_fail')),
  'the item shows it is being processed again');
select tests.check((select count(*) = 0 from public.moderator_photo_review_queue() where photo_id in (:'a_manual', :'b_fail')),
  'decided and restarted items leave the queue');

-- ---------------------------------------------------------------- actions are audited
select public.moderate_profile_photo(:'b_rej', 'reject', 'not a real photo of a person');
select public.moderate_profile_photo(:'b_rem', 'remove', 'spam');
select public.moderate_user(:bob, 'require_reverification', 'photos do not match verification');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.moderation_actions
  where action = 'photo_reject' and media_asset_id = :'b_rej' and moderator_id = :mod and target_user_id = :bob and created_at is not null),
  'rejection is audited with photo, user, moderator and time');
select tests.check((select count(*) = 1 from private.photo_processing_events where photo_id = :'b_rej' and event_type = 'rejected' and actor_id = :mod),
  'and in the photo history');
select tests.check((select count(*) = 1 from private.moderation_actions
  where action = 'photo_remove' and media_asset_id = :'b_rem' and moderator_id = :mod and target_user_id = :bob),
  'removal is audited');
select tests.check((select count(*) = 1 from private.photo_processing_events where photo_id = :'b_rem' and event_type = 'removed' and actor_id = :mod),
  'and in the photo history');
select tests.check((select count(*) = 1 from private.moderation_actions
  where action = 'require_reverification' and moderator_id = :mod and target_user_id = :bob),
  're-verification is audited');
select tests.check((select verification_status = 'reverification_required' from public.profiles where id = :bob),
  're-verification takes effect');
select tests.check((select count(*) = 1 from private.moderation_actions
  where action = 'photo_retry' and media_asset_id = :'b_fail' and moderator_id = :mod2),
  'retries are audited');
select tests.check((select count(*) = 1 from private.moderation_actions
  where action = 'photo_reject' and media_asset_id = :'a_manual' and moderator_id = :mod2),
  'the other moderator''s decision is audited under their id');
select tests.check((select count(*) = 0 from private.moderation_actions m
  where m.reason ~* '(https?://|token=|\.jpg)'), 'no URLs or paths in the audit trail');
select tests.check((select count(*) = 1 from private.media_deletion_queue where media_asset_id = :'b_rem'),
  'the removed file is queued for deletion');

-- ---------------------------------------------------------------- notes
select tests.become('authenticated', :mod, :mod_claims);
select public.moderator_add_photo_note(:'b_dup', '  Same photo as another account; asked for re-verification.  ') as note_id \gset
select tests.expect_error(format($$select public.moderator_add_photo_note('%s', '   ')$$, :'b_dup'), 'check',
  'empty notes are refused');
select tests.become('authenticated', :mod2, :mod_claims);
select tests.check((select count(*) = 1 from public.moderator_photo_notes(:'b_dup')
  where body = 'Same photo as another account; asked for re-verification.' and moderator_id = :mod and created_at is not null),
  'notes record the moderator and time and are shared with other moderators');
select tests.become_admin();
select tests.expect_error(format($$update private.moderator_notes set body = 'edited' where id = %s$$, :note_id), 'append-only',
  'notes cannot be edited');
select tests.expect_error(format($$delete from private.moderator_notes where id = %s$$, :note_id), 'append-only',
  'notes cannot be deleted');
select tests.check((select count(*) = 1 from private.moderation_actions where action = 'photo_note_added' and media_asset_id = :'b_dup'),
  'adding a note is audited');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('my_profile_photos', 'get_profile_photos', 'get_my_discovery_eligibility')
    and pg_get_function_result(p.oid) ~* 'note'),
  'user-facing functions never return notes');

-- ---------------------------------------------------------------- child-safety escalation
select tests.become('authenticated', :mod, :mod_claims);
select public.flag_media_for_child_safety(:'b_dup', 'underage_user_concern');
select public.flag_media_for_child_safety(:'b_dup', 'underage_user_concern');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.child_safety_cases where media_asset_id = :'b_dup'),
  'escalating twice opens one case');
select tests.check((select count(*) = 2 from private.moderation_actions
  where action = 'photo_escalate_child_safety' and media_asset_id = :'b_dup' and moderator_id = :mod and target_user_id = :bob),
  'each escalation is audited with the moderator');
select tests.check((select moderation_state = 'quarantined' from private.media_assets where id = :'b_dup'), 'the photo is quarantined');
select tests.become('authenticated', :mod2, :mod_claims);
select tests.check((select count(*) = 0 from public.moderator_photo_review_item(:'b_dup')),
  'another moderator with the item open can no longer load it');
select tests.check((select count(*) = 0 from public.moderator_photo_notes(:'b_dup')), 'or its notes');
select tests.expect_error(format($$select public.moderate_profile_photo('%s', 'approve')$$, :'b_dup'), 'not available',
  'or approve it');
select tests.check((select count(*) = 0 from public.moderator_photo_review_queue() where owner_id = :bob),
  'the held account disappears from the queue');

-- ---------------------------------------------------------------- queue after all decisions
select tests.check((select count(*) = 0 from public.moderator_photo_review_queue()),
  'the queue is empty once every item is handled');
