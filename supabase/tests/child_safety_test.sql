-- Child safety: cases, holds, quarantine, reviewer-only evidence access.
--
-- Uses ONLY synthetic fixtures: placeholder UUIDs, a fake SHA-256 of 64
-- zeros-and-letters and made-up provider references. No images, real
-- hashes or any illegal material are used or required.

\set alice '''11111111-1111-1111-1111-111111111111'''
\set bob '''22222222-2222-2222-2222-222222222222'''
\set carol '''33333333-3333-3333-3333-333333333333'''
\set dave '''44444444-4444-4444-4444-444444444444'''
\set mod '''99999999-9999-9999-9999-999999999999'''
\set reviewer '''88888888-8888-8888-8888-888888888888'''
\set mod_claims '''{"app_metadata": {"role": "moderator"}, "aal": "aal2"}'''
\set reviewer_claims '''{"app_metadata": {"role": "child_safety_reviewer"}, "aal": "aal2"}'''
\set asset '''cccccccc-0000-0000-0000-000000000001'''

select tests.make_eligible(:alice, 'Alice');
select tests.make_eligible(:bob, 'Bob');
select tests.make_eligible(:carol, 'Carol');
select tests.make_eligible(:dave, 'Dave');
insert into auth.users (id, email) values (:reviewer, 'reviewer@example.com');

insert into private.media_assets (id, owner_id, purpose, bucket_id, object_path, moderation_state, sha256)
values (:asset, :alice, 'profile_photo', 'profile-media', 'synthetic/alice-1.jpg', 'approved', repeat('0a', 32));

select tests.become('authenticated', :bob);
select tests.check(public.resolve_public_media(:asset) = 'synthetic/alice-1.jpg', 'setup: media is visible before any flag');
select tests.become_admin();

-- ---------------------------------------------------------------- reports
select tests.become('authenticated', :bob);
select public.submit_report(:alice, 'suspected_csam') as cs_report \gset
select tests.check((select count(*) = 1 from public.my_submitted_reports()), 'reporter can see their own report');
select tests.become('authenticated', :alice);
select tests.expect_error('select * from private.user_reports', 'permission denied', 'reported user cannot read reports');
select tests.expect_error('select * from private.child_safety_cases', 'permission denied', 'reported user cannot read cases');
select tests.check((select count(*) = 0 from public.my_submitted_reports()), 'reported user cannot learn who reported them');
select tests.check((public.get_my_discovery_eligibility() -> 'reasons') = '["account_unavailable"]'::jsonb,
  'the held user sees a generic reason, not the child-safety case');
select tests.become_admin();

select tests.check((select priority = 'critical' and category = 'suspected_csam' and legal_hold from private.child_safety_cases
  where report_id = :'cs_report'), 'CSAM report opens a critical case with legal hold');
select tests.check((select priority = 'critical' from private.user_reports where id = :'cs_report'),
  'child-safety reports outrank normal reports');
select tests.check((select count(*) = 0 from private.abuse_signals where user_id = :alice),
  'child-safety reports stay out of the ordinary signal queue');

-- ---------------------------------------------------------------- visibility override
select tests.check(private.has_active_safety_hold(:alice), 'account is held immediately');
select tests.check((select verification_status = 'verified' and profile_completed from public.profiles where id = :alice),
  'setup: the held profile is otherwise complete and verified');
select tests.check(not private.is_discovery_eligible(:alice), 'a child-safety hold overrides normal eligibility');
select tests.check(private.trust_level(:alice) = 'restricted', 'held accounts are restricted');
select tests.check(not private.can_interact(:bob, :alice), 'no likes, matches or messages with a held account');
select tests.check(not private.media_is_publicly_servable(:asset), 'held owner''s media is not served');

-- ---------------------------------------------------------------- provider match + quarantine
select tests.become('authenticated', :bob, '{"role": "service_role"}');
select tests.expect_error(format($$select public.report_child_safety_media_match('%s', 'known_csam_hash_match', 'x')$$, :asset),
  'permission denied', 'a forged service_role claim cannot report provider matches');
select tests.become('service_role', null);
select public.report_child_safety_media_match(:asset, 'known_csam_hash_match', 'synthetic-provider-ref-001') as match_case \gset
select tests.become_admin();
select tests.check((select moderation_state = 'quarantined' from private.media_assets where id = :asset), 'matched media is quarantined');
select tests.check((select legal_hold and priority = 'critical' and source = 'hash_match_provider' from private.child_safety_cases where id = :'match_case'),
  'known hash matches take the critical, preserved path');
select tests.check((select count(*) = 0 from private.child_safety_events where details::text ~ '\.jpg|http|sha'),
  'events never contain paths, URLs or hashes');

select tests.become('authenticated', :bob);
select tests.check(public.resolve_public_media(:asset) is null, 'quarantined media cannot be read through user APIs');
select tests.expect_error('select * from private.media_assets', 'permission denied', 'media records are unreachable');
select tests.expect_error('select * from private.media_quarantine', 'permission denied', 'quarantine records are unreachable');

-- ---------------------------------------------------------------- nobody ordinary can clear it
select tests.become('authenticated', :alice);
select tests.expect_error(format($$select public.child_safety_release('%s', true)$$, :'match_case'), 'not_authorized',
  'the uploader cannot lift quarantine');
select tests.expect_error($$update private.account_safety_holds set released_at = now()$$, 'permission denied', 'users cannot release holds');
select tests.expect_error($$update private.media_assets set moderation_state = 'approved'$$, 'permission denied', 'users cannot change media state');
select tests.become_admin();
select tests.expect_error(format($$update private.media_assets set moderation_state = 'approved' where id = '%s'$$, :asset),
  'child-safety review', 'even direct admin updates cannot bypass quarantine');
select tests.expect_error(format($$update private.media_assets set object_path = 'other.jpg' where id = '%s'$$, :asset),
  'immutable', 'quarantined media cannot be swapped');
select tests.expect_error('update private.account_safety_holds set released_at = now()', 'only child-safety review',
  'holds cannot be released outside review');
select tests.expect_error('delete from private.account_safety_holds', 'cannot be deleted', 'holds cannot be deleted');

-- ---------------------------------------------------------------- reviewer-only evidence
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.child_safety_access_evidence('%s')$$, :'match_case'), 'not_authorized',
  'ordinary moderators cannot access child-safety evidence');
select tests.expect_error(format($$select public.child_safety_update_case('%s', 'under_review')$$, :'match_case'), 'not_authorized',
  'ordinary moderators cannot work child-safety cases');
select tests.become('authenticated', :reviewer, '{"app_metadata": {"role": "child_safety_reviewer"}}');
select tests.expect_error(format($$select public.child_safety_access_evidence('%s')$$, :'match_case'), 'not_authorized',
  'reviewers without MFA are refused');
select tests.become('authenticated', :reviewer, :reviewer_claims);
select tests.check((public.child_safety_access_evidence(:'match_case') ->> 'bucket_id') = 'profile-media',
  'an MFA child-safety reviewer can locate the evidence');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.child_safety_events where case_id = :'match_case'
  and event_type = 'evidence_accessed' and actor_id = :reviewer), 'every evidence access is audited');
select tests.expect_error('update private.child_safety_events set actor_type = ''system''', 'append-only', 'child-safety events are append-only');
select tests.expect_error('delete from private.child_safety_events', 'append-only', 'child-safety events cannot be deleted');
select tests.check((select public = false from storage.buckets where id = 'child-safety-evidence'), 'evidence bucket is private');
select tests.check((select count(*) = 0 from pg_policies where schemaname = 'storage' and qual ilike '%child-safety-evidence%'),
  'no storage policy grants user access to the evidence bucket');

-- ---------------------------------------------------------------- legal steps are human and separate
select tests.become('authenticated', :reviewer, :reviewer_claims);
select tests.expect_error(format($$select public.child_safety_record_external_report('%s', 'synthetic-ref')$$, :'match_case'),
  'escalated to legal', 'external reports are only recorded after legal escalation');
select public.child_safety_update_case(:'match_case', 'escalated_legal');
select public.child_safety_record_external_report(:'match_case', 'synthetic-ref-xyz');
select public.child_safety_update_case(:'match_case', 'closed_no_violation');
select tests.expect_error(format($$select public.child_safety_release('%s', true)$$, :'match_case'), 'legal hold',
  'media under legal hold is never released back to users');
select tests.become_admin();

-- ---------------------------------------------------------------- underage concern
select tests.become('authenticated', :alice);
select public.submit_report(:dave, 'underage_concern');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.child_safety_cases where subject_user_id = :dave and category = 'underage_user_concern'),
  'an underage concern opens a child-safety case');
select tests.check(not private.has_active_safety_hold(:dave), 'a single underage report alone does not hold the account');
select tests.become('authenticated', :bob);
select public.submit_report(:dave, 'underage_concern');
select tests.become_admin();
select tests.check(private.has_active_safety_hold(:dave) and not private.is_discovery_eligible(:dave),
  'a second independent underage concern holds the account and removes eligibility');
select tests.expect_error(format($$update public.profiles set birth_date = '2015-01-01' where id = '%s'$$, :dave),
  'under_minimum_age', 'no one, not even an admin, can store an under-18 birth date');

-- ---------------------------------------------------------------- release after review
select (array_agg(id order by created_at))[1] as dave_case1, (array_agg(id order by created_at))[2] as dave_case2
from private.child_safety_cases where subject_user_id = :dave \gset
select tests.become('authenticated', :reviewer, :reviewer_claims);
select tests.expect_error('select * from private.child_safety_cases', 'permission denied', 'even reviewers work only through audited functions');
select public.child_safety_update_case(:'dave_case1', 'closed_no_violation');
select public.child_safety_update_case(:'dave_case2', 'closed_no_violation');
select public.child_safety_release(:'dave_case1');
select public.child_safety_release(:'dave_case2');
select tests.become_admin();
select tests.check(not private.has_active_safety_hold(:dave) and private.is_discovery_eligible(:dave),
  'a reviewer can release a hold after closing the case');
select tests.check((select count(*) >= 1 from private.child_safety_events e join private.child_safety_cases c on c.id = e.case_id
  where c.subject_user_id = :dave and e.event_type = 'hold_released' and e.actor_id = :reviewer), 'releases are audited');
