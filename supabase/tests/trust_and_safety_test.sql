-- Trust & safety: eligibility, blocks, reports, signals, scanning,
-- moderation, rate limits, message primitives, duplicate images.
-- All fixtures are synthetic.

\set alice '''11111111-1111-1111-1111-111111111111'''
\set bob '''22222222-2222-2222-2222-222222222222'''
\set mod '''99999999-9999-9999-9999-999999999999'''
\set carol '''33333333-3333-3333-3333-333333333333'''
\set mod_claims '''{"app_metadata": {"role": "moderator"}, "aal": "aal2"}'''

select tests.make_eligible(:alice, 'Alice');
select tests.make_eligible(:bob, 'Bob');
insert into auth.users (id, email) values (:carol, 'carol@example.com');

-- ---------------------------------------------------------------- eligibility
select tests.check(private.is_discovery_eligible(:alice), 'a confirmed, complete, verified, active user is eligible');
select tests.check(private.trust_level(:alice) = 'verified', 'new verified account is "verified", not "established"');
select tests.check(not private.is_discovery_eligible(:carol), 'unconfirmed user without a profile is not eligible');
select tests.check(private.discovery_ineligibility_reasons(:carol) @> array['email_unconfirmed', 'profile_incomplete', 'verification_required', 'account_not_active'],
  'every missing requirement is reported internally');

update auth.users set email_confirmed_at = null where id = :alice;
select tests.check(not private.is_discovery_eligible(:alice), 'unconfirmed email blocks eligibility');
update auth.users set email_confirmed_at = now() where id = :alice;

update public.profiles set verification_status = 'pending' where id = :alice;
select tests.check(not private.is_discovery_eligible(:alice), 'pending verification is not eligible');
update public.profiles set verification_status = 'verified' where id = :alice;

select tests.become('authenticated', :carol);
select tests.check((public.get_my_discovery_eligibility() -> 'reasons') = '["email_unconfirmed", "profile_incomplete", "verification_required", "account_unavailable"]'::jsonb,
  'users get only coarse reasons');
select tests.become('authenticated', :alice);
select tests.check((public.get_my_discovery_eligibility() ->> 'eligible')::boolean, 'eligible user sees eligible');

-- ---------------------------------------------------------------- forging state
select tests.expect_error($$update private.accounts set status = 'active', manual_review_required = false$$, 'permission denied',
  'users cannot change account state');
select tests.expect_error($$select private.trust_level(auth.uid())$$, 'permission denied', 'users cannot call trust functions');
select tests.expect_error($$select private.is_discovery_eligible(auth.uid())$$, 'permission denied', 'users cannot call internal eligibility');
select tests.expect_error($$select private.risk_score(auth.uid())$$, 'permission denied', 'risk score is not exposed');
select tests.expect_error($$update public.profiles set verification_status = 'verified'$$, 'permission denied', 'users cannot set verification');
select tests.check((select count(*) = 0 from information_schema.columns where table_schema = 'public'
  and column_name ~ '(eligib|trust|risk)'), 'no client-writable eligibility, trust or risk columns exist');

-- ---------------------------------------------------------------- blocks
select public.block_user(:bob);
select tests.check((select count(*) = 1 from public.my_blocked_users()), 'alice sees who she blocked');
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.my_blocked_users()), 'bob cannot see that alice blocked him');
select tests.expect_error('select * from private.blocks', 'permission denied', 'block records are private');
select public.block_user('00000000-0000-0000-0000-000000000042');
select tests.expect_error(format($$select public.block_user('%s')$$, :bob), 'invalid block target', 'users cannot block themselves');
select tests.become_admin();
select tests.check(not private.can_interact(:alice, :bob), 'blocker cannot interact with blocked user');
select tests.check(not private.can_interact(:bob, :alice), 'blocked user cannot interact with blocker');
select tests.check((private.check_outbound_message(:bob, :alice, 'hi', true) ->> 'allowed')::boolean = false,
  'future messaging refuses blocked pairs');
select tests.check((select count(*) = 1 from private.blocks), 'blocking an unknown account creates nothing');
select tests.become('authenticated', :alice);
select public.unblock_user(:bob);
select tests.become_admin();
select tests.check(private.can_interact(:alice, :bob), 'unblocking restores interaction');

-- ---------------------------------------------------------------- reports
select tests.become('authenticated', :bob);
select public.submit_report(:alice, 'spam', 'Sends the same link to everyone') as report_id \gset
select tests.check(public.submit_report(:alice, 'spam') = :'report_id', 'repeat report while open returns the same report');
select tests.check((select status = 'received' from public.my_submitted_reports()), 'reporter sees their report as received');
select tests.expect_error(format($$select public.submit_report('%s', 'spam')$$, :bob), 'invalid report target', 'users cannot report themselves');
select tests.expect_error(format($$select public.submit_report('%s', 'not_a_category')$$, :alice), 'invalid report category', 'unknown categories are rejected');
select tests.expect_error($$update private.user_reports set status = 'dismissed'$$, 'permission denied', 'reporters cannot resolve reports');
select tests.expect_error(format($$select public.moderate_user('%s', 'dismiss', 'x', '%s')$$, :alice, :'report_id'), 'not_authorized',
  'reporters cannot resolve reports through moderation functions');

select tests.become('authenticated', :alice);
select tests.expect_error('select * from private.user_reports', 'permission denied', 'reported user cannot read reports');
select tests.check((select count(*) = 0 from public.my_submitted_reports()), 'reported user cannot see reports about them');
select tests.expect_error('select * from private.abuse_signals', 'permission denied', 'reported user cannot read signals');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.abuse_signals where user_id = :alice and signal_type = 'user_report' and source = 'user_report'),
  'a report adds a review signal');
select tests.check((select status = 'active' from private.accounts where user_id = :alice), 'one report never restricts an account');
select tests.expect_error(format($$update private.user_reports set reporter_id = '%s' where id = '%s'$$, :carol, :'report_id'),
  'immutable', 'report contents are immutable even for admins');

-- ---------------------------------------------------------------- signals are protected
select tests.become('authenticated', :alice);
select tests.expect_error('delete from private.abuse_signals', 'permission denied', 'users cannot remove abuse signals');
select tests.expect_error($$update private.abuse_signals set review_status = 'dismissed'$$, 'permission denied', 'users cannot dismiss abuse signals');
select tests.expect_error('select public.review_abuse_signal(1, ''dismissed'')', 'not_authorized', 'users cannot use the signal review function');
select tests.become_admin();

-- ---------------------------------------------------------------- shared IP is context only
select private.record_abuse_signal(:bob, 'shared_ip', 'high') from generate_series(1, 30);
select tests.check(private.trust_level(:bob) = 'verified' and private.is_discovery_eligible(:bob),
  'shared-IP signals alone never affect trust or eligibility');

-- ---------------------------------------------------------------- content scanning
select tests.become('authenticated', :bob);
update public.profiles set bio = E'Fog, velvet & rain.\nFind me at the cemetery at midnight.';
select tests.become_admin();
select tests.check((select count(*) = 0 from private.abuse_signals where user_id = :bob and source = 'content_scan'),
  'an ordinary gothic bio raises nothing');

select tests.become('authenticated', :alice);
update public.profiles set bio = 'Selling my pics!! $20 per pic, custom content, cashapp $ravenqueen, link in bio onlyfans.com/raven';
select tests.become_admin();
select tests.check((select array_agg(distinct signal_type order by signal_type) from private.abuse_signals
  where user_id = :alice and source = 'content_scan') @> array['paid_content_solicitation', 'payment_handle', 'price_list_pattern', 'promotional_language', 'external_link'],
  'a content-sales bio produces commercial signals');
select tests.check((select count(*) = 0 from private.abuse_signals where user_id = :alice and details::text ilike '%raven%'),
  'signals never store the profile text');
select tests.check(private.trust_level(:alice) = 'review_required', 'accumulated signals require review');
select tests.check(not private.is_discovery_eligible(:alice), 'review_required removes eligibility');
select tests.check((select status = 'active' from private.accounts where user_id = :alice), 'keywords alone never suspend or restrict');

-- ---------------------------------------------------------------- moderation
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.moderate_user('%s', 'warn', 'x')$$, :mod), 'own account', 'moderators cannot act on themselves');
select public.moderate_user(:alice, 'clear_review', 'false positive', :'report_id');
select tests.become_admin();
select tests.check(private.is_discovery_eligible(:alice), 'moderator can clear a review');
select tests.check((select status = 'actioned' and reviewer_id = :mod from private.user_reports where id = :'report_id'), 'moderator resolves the report');
select tests.check((select count(*) = 1 from private.moderation_actions where target_user_id = :alice and moderator_id = :mod),
  'moderator action is audited');
select tests.expect_error('update private.moderation_actions set action = ''ban''', 'append-only', 'moderation log cannot be edited');
select tests.expect_error('delete from private.moderation_actions', 'append-only', 'moderation log cannot be deleted');
select tests.become('authenticated', :alice);
select tests.expect_error('select * from private.moderation_actions', 'permission denied', 'users cannot read the moderation log');
select tests.become('authenticated', :mod, :mod_claims);
select public.moderate_user(:bob, 'restrict', 'test restriction');
select tests.become_admin();
select tests.check(private.trust_level(:bob) = 'restricted' and not private.is_discovery_eligible(:bob), 'restricted accounts are not eligible');
select tests.become('authenticated', :mod, :mod_claims);
select public.moderate_user(:bob, 'lift_restriction', 'resolved');
select tests.become_admin();

-- ---------------------------------------------------------------- profile change re-checks
select tests.become('authenticated', :alice);
update public.profiles set display_name = 'Alicia';
select tests.become_admin();
select tests.check((select count(*) = 1 from private.profile_change_events where user_id = :alice and change_kind = 'identity'),
  'identity changes after verification are recorded');
select tests.become('authenticated', :alice);
update public.profiles set birth_date = '1991-01-01';
select tests.become_admin();
select tests.check((select manual_review_required from private.accounts where user_id = :alice),
  'changing birth date after verification requires review');
update private.accounts set manual_review_required = false, created_at = now() - interval '60 days' where user_id = :alice;
update private.abuse_signals set review_status = 'dismissed' where user_id = :alice;
select tests.check(private.trust_level(:alice) = 'verified', 'recent major changes prevent "established" trust');
update private.profile_change_events set created_at = now() - interval '30 days' where user_id = :alice;
select tests.check(private.trust_level(:alice) = 'established', 'trust becomes established only after a quiet period');

-- ---------------------------------------------------------------- new-account rate limits
select tests.check((select count(*) filter (where private.consume_user_action(:carol, 'like')) = 50 from generate_series(1, 60)),
  'new accounts get the stricter like limit');
select tests.check((select count(*) filter (where private.consume_user_action(:alice, 'like')) = 60 from generate_series(1, 60)),
  'older accounts get the normal limit');

-- ---------------------------------------------------------------- message primitives
do $$
begin
  for i in 1..6 loop
    perform tests.make_eligible(('00000000-0000-0000-0000-00000000000' || i)::uuid, 'R' || i);
  end loop;
end $$;
select tests.check((select count(*) = 5 from generate_series(1, 5) i
  where (private.check_outbound_message(:bob, ('00000000-0000-0000-0000-00000000000' || i)::uuid, 'Hey  gorgeous, check out my page', false) ->> 'allowed')::boolean),
  'content signals alone do not block delivery');
select tests.check((select count(*) = 1 from private.abuse_signals where user_id = :bob and signal_type = 'duplicate_message_blast'),
  'the same message to many people is flagged');
select tests.check(private.trust_level(:bob) = 'review_required', 'a promotional blast sends the sender to review');
select tests.check((private.check_outbound_message(:bob, '00000000-0000-0000-0000-000000000006', 'Hey gorgeous, check out my page', false) ->> 'allowed')::boolean = false,
  'accounts under review cannot keep messaging');
select tests.check((select status = 'active' from private.accounts where user_id = :bob), 'review is not a suspension');
update private.abuse_signals set review_status = 'dismissed' where user_id = :bob;
select tests.check((select count(*) = 0 from information_schema.columns where table_schema = 'private'
  and table_name = 'message_fingerprint_events' and column_name ~ '(body|text|content)'), 'message text is never stored');
select private.check_outbound_message(:alice, :bob, 'add me on telegram, cashapp me', true);
select tests.check((select count(*) = 1 from private.abuse_signals where user_id = :alice and signal_type = 'immediate_commercial_solicitation'),
  'commercial push in a first message is flagged');
update private.accounts set created_at = now() where user_id = :bob;
delete from private.rate_limit_events;
select tests.check((select count(*) filter (where (private.check_outbound_message(:bob, '00000000-0000-0000-0000-000000000001', 'hello ' || g, true) ->> 'allowed')::boolean) = 20
  from generate_series(1, 25) g), 'first messages from new accounts are rate limited');

-- ---------------------------------------------------------------- duplicate images
insert into private.media_assets (id, owner_id, purpose, bucket_id, object_path, moderation_state)
values ('aaaaaaaa-0000-0000-0000-000000000001', :alice, 'profile_photo', 'profile-media', 'a/1.jpg', 'approved'),
       ('bbbbbbbb-0000-0000-0000-000000000001', :bob,   'profile_photo', 'profile-media', 'b/1.jpg', 'pending_scan');
select private.register_media_hashes('aaaaaaaa-0000-0000-0000-000000000001', repeat('a', 64), B'1010101010101010101010101010101010101010101010101010101010101010');
select tests.check(private.register_media_hashes('bbbbbbbb-0000-0000-0000-000000000001', repeat('b', 64),
  B'1010101010101010101010101010101010101010101010101010101010101011') = 1, 'a near-duplicate of another account''s photo is detected');
select tests.check((select related_user_id = :alice from private.abuse_signals where user_id = :bob and signal_type = 'reused_public_image'),
  'the reuse signal links the original account for review');
select tests.check((select count(*) = 0 from information_schema.columns where table_schema = 'private'
  and column_name ~ '(face|embedding|biometric|template)'), 'no biometric columns exist');
update private.abuse_signals set review_status = 'dismissed' where user_id = :alice;
select tests.become('authenticated', '00000000-0000-0000-0000-000000000002');
select tests.check(public.resolve_public_media('aaaaaaaa-0000-0000-0000-000000000001') = 'a/1.jpg', 'approved media resolves for eligible viewers');
select tests.check(public.resolve_public_media('bbbbbbbb-0000-0000-0000-000000000001') is null, 'unapproved media does not resolve');
select tests.become('authenticated', :carol);
select tests.check(public.resolve_public_media('aaaaaaaa-0000-0000-0000-000000000001') is null, 'ineligible viewers get nothing');
select tests.become('authenticated', :bob);
select tests.expect_error('select * from private.media_assets', 'permission denied', 'media records are private');
select tests.become_admin();
select tests.expect_error($$update private.media_assets set object_path = 'swap.jpg' where owner_id = '11111111-1111-1111-1111-111111111111'$$,
  'immutable', 'media identity cannot be swapped');
