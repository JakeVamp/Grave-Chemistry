-- Live photo verification: sessions, storage policies, review paths, audit.

\set alice '''11111111-1111-1111-1111-111111111111'''
\set bob '''22222222-2222-2222-2222-222222222222'''
\set mod '''99999999-9999-9999-9999-999999999999'''
\set mod_claims '''{"app_metadata": {"role": "moderator"}, "aal": "aal2"}'''

-- Setup: complete profiles for Alice and Bob (as a trusted admin)
insert into public.profiles (id, display_name, birth_date, location_city, location_state_or_region,
  gender, community_identity, dating_preference)
values
  (:alice, 'Alice', '1995-01-01', 'Salem', 'MA', 'woman', 'goth', 'goth_seeking_goth'),
  (:bob,   'Bob',   '1994-01-01', 'Salem', 'MA', 'man',   'normie', 'normie_seeking_goth');
insert into public.profiles (id, display_name) values (:mod, 'Mod');

select tests.check((select public = false from storage.buckets where id = 'verification-media'),
  'verification bucket is private');

-- ---------------------------------------------------------------- start
select tests.become('authenticated', :mod);
select tests.check((public.start_verification_session() ->> 'outcome') = 'profile_incomplete',
  'incomplete profile cannot start verification');

select tests.become('authenticated', :alice);
select public.start_verification_session() as started \gset
select tests.check((:'started'::jsonb ->> 'outcome') = 'issued', 'alice gets a session');
select tests.check((:'started'::jsonb ->> 'challenge_type') in
  ('look_straight', 'turn_head_left', 'turn_head_right', 'blink', 'smile'), 'server chose a challenge');
select (:'started'::jsonb ->> 'session_id') as alice_session \gset
select :'alice_session' || '/' || md5(random()::text) || '.jpg' as alice_path \gset

-- Private data is unreachable
select tests.expect_error('select * from private.verification_sessions', 'permission denied', 'users cannot read sessions');
select tests.expect_error('select * from private.verification_audit_log', 'permission denied', 'users cannot read the audit log');
select tests.expect_error($$insert into private.verification_audit_log (event_type, user_id, actor_type) values ('approved', auth.uid(), 'moderator')$$,
  'permission denied', 'users cannot create audit records');
select tests.expect_error($$select private.set_verification_status(auth.uid(), 'verified')$$, 'permission denied',
  'users cannot call the status function');
select tests.expect_error($$update private.verification_sessions set status = 'approved'$$, 'permission denied',
  'users cannot approve sessions directly');

-- ---------------------------------------------------------------- upload
select tests.expect_error(format($$insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', '%s/photo.jpg', auth.uid())$$, :alice),
  'row-level security', 'paths must be <session>/<random>.jpg, not user IDs');
insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', :'alice_path', auth.uid()::text);
select tests.check((select count(*) = 1 from storage.objects where bucket_id = 'verification-media'), 'alice can read her own photo');

select tests.become('authenticated', :bob);
select tests.expect_error(format($$insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', '%s/%s.jpg', auth.uid())$$,
  :'alice_session', md5('x')), 'row-level security', 'bob cannot upload into alice''s session');
select tests.check((select count(*) = 0 from storage.objects where bucket_id = 'verification-media'), 'bob cannot see alice''s photo');
select tests.check((public.submit_verification_session(:'alice_session', :'alice_path') ->> 'outcome') = 'session_not_found',
  'bob cannot submit alice''s session');

-- ---------------------------------------------------------------- submit
select tests.become('authenticated', :alice);
select tests.check((public.submit_verification_session(:'alice_session', :'alice_session' || '/' || md5('missing') || '.jpg') ->> 'outcome') = 'media_missing',
  'submitting without an uploaded photo fails');
select public.submit_verification_session(:'alice_session', :'alice_path') as submitted \gset
select tests.check((:'submitted'::jsonb ->> 'verification_status') = 'pending', 'submission results in pending');
select tests.check((select verification_status = 'pending' and not verified_badge and verification_submitted_at is not null
  from public.profiles), 'profile is pending with no badge');
select tests.check((public.submit_verification_session(:'alice_session', :'alice_path') ->> 'outcome') = 'session_not_open',
  'a submitted session cannot be reused');
select tests.check((public.start_verification_session() ->> 'outcome') = 'already_submitted',
  'cannot start another session while pending');
select tests.expect_error(format($$insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', '%s/%s.jpg', auth.uid())$$,
  :'alice_session', md5('late')), 'row-level security', 'no uploads into a submitted session');

-- ---------------------------------------------------------------- self-approval
select tests.expect_error(format($$select public.review_verification_session('%s', 'approved')$$, :'alice_session'),
  'not_authorized', 'users cannot approve themselves');
select tests.become('authenticated', :alice, '{"app_metadata": {"role": "moderator"}}');
select tests.expect_error(format($$select public.review_verification_session('%s', 'approved')$$, :'alice_session'),
  'not_authorized', 'moderator role without MFA is refused');
select tests.become('authenticated', :alice, :mod_claims);
select tests.expect_error(format($$select public.review_verification_session('%s', 'approved')$$, :'alice_session'),
  'own verification', 'moderators cannot approve themselves');
select tests.become('authenticated', :alice);
select tests.expect_error(format($$select public.apply_verification_provider_result('%s', 'passed', 'x')$$, :'alice_session'),
  'permission denied', 'users cannot post provider results');
select tests.become('authenticated', :alice, '{"role": "service_role"}');
select tests.expect_error(format($$select public.apply_verification_provider_result('%s', 'passed', 'x')$$, :'alice_session'),
  'permission denied', 'a forged service_role claim is useless without the service_role database role');

-- ---------------------------------------------------------------- moderator approval
select tests.become('authenticated', :mod, :mod_claims);
select public.review_verification_session(:'alice_session', 'approved', 'looks good');
select tests.become_admin();
select tests.check((select verification_status = 'verified' and verified_badge and verification_reviewed_at is not null
  from public.profiles where id = :alice), 'moderator approval verifies and grants the badge');
select tests.check((select status = 'active' from private.accounts where user_id = :alice), 'account becomes active');
select tests.check((select actor_type = 'moderator' and actor_id = :mod from private.verification_audit_log
  where user_id = :alice and event_type = 'approved'), 'approval audited with moderator identity');
select tests.expect_error('update private.verification_audit_log set actor_type = ''system''', 'append-only', 'audit log cannot be edited');
select tests.expect_error('delete from private.verification_audit_log', 'append-only', 'audit log cannot be deleted');
select tests.check((select count(*) = 0 from private.verification_audit_log where details::text ~ '\.jpg|http'),
  'audit log holds no paths or URLs');

-- ---------------------------------------------------------------- expiry
select tests.become('authenticated', :bob);
select (public.start_verification_session() ->> 'session_id') as bob_session \gset
select :'bob_session' || '/' || md5(random()::text) || '.jpg' as bob_path \gset
insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', :'bob_path', auth.uid()::text);
select tests.become_admin();
update private.verification_sessions set created_at = now() - interval '1 hour', expires_at = now() - interval '1 minute'
where id = :'bob_session';
select tests.become('authenticated', :bob);
select tests.check((public.submit_verification_session(:'bob_session', :'bob_path') ->> 'outcome') = 'session_expired',
  'expired sessions cannot be submitted');
select tests.check((select verification_status = 'not_started' from public.profiles), 'bob is still not started');
select tests.expect_error(format($$insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', '%s/%s.jpg', auth.uid())$$,
  :'bob_session', md5('y')), 'row-level security', 'no uploads into an expired session');

-- ---------------------------------------------------------------- rejection and retry
select (public.start_verification_session() ->> 'session_id') as bob_session2 \gset
select :'bob_session2' || '/' || md5(random()::text) || '.jpg' as bob_path2 \gset
insert into storage.objects (bucket_id, name, owner_id) values ('verification-media', :'bob_path2', auth.uid()::text);
select tests.check((public.submit_verification_session(:'bob_session2', :'bob_path2') ->> 'outcome') = 'submitted', 'bob submits');
select tests.become('authenticated', :mod, :mod_claims);
select public.review_verification_session(:'bob_session2', 'rejected', 'photo too dark');
select tests.become('authenticated', :bob);
select tests.check((select verification_status = 'rejected' and not verified_badge from public.profiles), 'rejected gives no badge');
select tests.check((public.start_verification_session() ->> 'outcome') = 'issued', 'rejected users can retry');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.verification_audit_log where user_id = :bob and event_type = 'retry_requested'),
  'retry is audited');
select tests.check((select attempt_number = 3 from private.verification_sessions where user_id = :bob and status = 'issued'),
  'attempts are numbered by the server');

-- ---------------------------------------------------------------- rate limit
select tests.become('authenticated', :bob);
select public.start_verification_session(); -- 4th this hour
select public.start_verification_session(); -- 5th
select tests.check((public.start_verification_session() ->> 'outcome') = 'rate_limited', 'session creation is rate limited');

-- ---------------------------------------------------------------- repeated rejections
select tests.become_admin();
insert into private.verification_sessions (user_id, status, challenge_type, attempt_number, created_at, expires_at, reviewed_at)
select :bob, 'rejected', 'blink', 10 + g, now() - interval '1 day', now() - interval '1 day' + interval '10 minutes', now() - interval '1 day'
from generate_series(1, 2) g;
delete from private.rate_limit_events;
select tests.become('authenticated', :bob);
select tests.check((public.start_verification_session() ->> 'outcome') = 'too_many_attempts',
  'repeated rejections lock further attempts');

-- ---------------------------------------------------------------- reverification
select tests.become('authenticated', :alice);
select tests.expect_error(format($$select public.require_reverification('%s', 'x')$$, :bob), 'not_authorized',
  'users cannot revoke verification');
select tests.become('authenticated', :mod, :mod_claims);
select public.require_reverification(:alice, 'periodic re-check');
select tests.become_admin();
select tests.check((select verification_status = 'reverification_required' and not verified_badge
  from public.profiles where id = :alice), 'reverification_required gives no badge');
select tests.check((select count(*) = 1 from private.verification_audit_log where user_id = :alice and event_type = 'approved'),
  'history is kept after revocation');
select tests.expect_error($$select private.set_verification_status('11111111-1111-1111-1111-111111111111', 'verified')$$,
  'invalid_verification_transition', 'reverification_required cannot jump to verified');

-- ---------------------------------------------------------------- retention
update private.verification_sessions set media_retain_until = now() - interval '1 second' where id = :'alice_session';
select tests.check((select count(*) = 1 from private.verification_media_due_for_deletion() where session_id = :'alice_session'),
  'media past retention is listed for deletion');
select private.mark_verification_media_deleted(:'alice_session');
select tests.check((select count(*) = 0 from private.verification_media_due_for_deletion() where session_id = :'alice_session'),
  'deleted media is not listed again');
select tests.check((select media_retain_until is not null from private.verification_sessions where id = :'bob_session'),
  'abandoned (expired) media gets a retention deadline');
