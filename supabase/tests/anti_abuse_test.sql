-- Multi-account safeguards: accounts, devices, phones, deletion, sign-up hook.

\set alice '''11111111-1111-1111-1111-111111111111'''
\set bob '''22222222-2222-2222-2222-222222222222'''
\set mod '''99999999-9999-9999-9999-999999999999'''
\set mod_claims '''{"app_metadata": {"role": "moderator"}, "aal": "aal2"}'''
\set install '''6f1c2b9e-3a4d-4e5f-8a6b-7c8d9e0f1a2b'''

select tests.check((select count(*) = 3 from private.accounts where status = 'pending_verification'),
  'every auth user gets an account in pending_verification');

-- ---------------------------------------------------------------- account status
select tests.become('authenticated', :alice);
select tests.check(public.get_my_account_status() = 'pending_verification', 'users can read their own status');
select tests.expect_error('select * from private.accounts', 'permission denied', 'users cannot read account records');
select tests.expect_error($$update private.accounts set status = 'active'$$, 'permission denied', 'users cannot change their status');
select tests.expect_error(format($$select public.set_account_status('%s', 'active', 'x')$$, :alice), 'not_authorized',
  'users cannot use the moderator status function');
select tests.expect_error('select * from private.abuse_signals', 'permission denied', 'users cannot read abuse flags');
select tests.become('authenticated', :mod, :mod_claims);
select tests.expect_error(format($$select public.set_account_status('%s', 'active', 'x')$$, :mod), 'own account',
  'moderators cannot change their own status');
select public.set_account_status(:bob, 'restricted', 'test');
select tests.become_admin();
select tests.check((select status = 'restricted' from private.accounts where user_id = :bob), 'moderator can restrict');
select tests.check((select count(*) = 1 from private.account_status_changes where user_id = :bob), 'status change is recorded');

-- ---------------------------------------------------------------- shared IP is not proof
select private.record_abuse_signal(:alice, 'shared_ip', 'low') from generate_series(1, 20);
select tests.check((select status = 'pending_verification' from private.accounts where user_id = :alice),
  'shared-IP signals never change account status');
select tests.check((select count(*) = 1 from private.abuse_signals where user_id = :alice and signal_type = 'shared_ip'),
  'repeat signals collapse into one open flag for review');

-- ---------------------------------------------------------------- devices
select tests.become('authenticated', :alice);
select public.register_device(:install, 'ios');
select tests.expect_error($$select public.register_device('AA:BB:CC:DD:EE:FF', 'ios')$$, 'invalid install id',
  'hardware identifiers are rejected');
select tests.expect_error('select * from private.devices', 'permission denied', 'users cannot read device records');
select tests.become('authenticated', :bob);
select public.register_device(:install, 'ios');
select tests.become_admin();
select tests.check((select count(*) = 2 from private.devices), 'same install on two accounts creates two separate rows');
select tests.check((select count(*) = 1 from private.devices where user_id = :alice), 'bob did not take over alice''s device row');
select tests.check((select count(*) = 0 from private.devices where install_id_hash = :install), 'install IDs are stored hashed');
insert into auth.users (id, email) values ('33333333-3333-3333-3333-333333333333', 'carol@example.com');
select tests.become('authenticated', '33333333-3333-3333-3333-333333333333');
select public.register_device(:install, 'ios');
select tests.become_admin();
select tests.check((select count(*) = 1 from private.abuse_signals where signal_type = 'shared_install'),
  'a third account on one install is flagged for review');
select tests.check((select status = 'pending_verification' from private.accounts where user_id = '33333333-3333-3333-3333-333333333333'),
  'shared install alone does not restrict the account');

-- ---------------------------------------------------------------- phones
select tests.check(private.link_verified_phone(:alice, '+15551234567') = 'linked', 'alice links a verified phone');
select tests.check(private.link_verified_phone(:bob, '+15551234567') = 'phone_in_use',
  'the same phone cannot be attached to a second active account');
select tests.check((select count(*) = 1 from private.abuse_signals where user_id = :bob and signal_type = 'shared_phone'),
  'attempted phone reuse is flagged');
select tests.expect_error($$insert into private.phone_identities (user_id, phone_hash) values ('22222222-2222-2222-2222-222222222222', private.hash_identifier('+15551234567'))$$,
  'phone_identities_one_active_account_idx', 'uniqueness is enforced by the database itself');
select tests.check((select count(*) = 0 from private.phone_identities where phone_hash like '%555%'), 'phone numbers are stored hashed');
select tests.check((select count(*) = 0 from information_schema.columns where table_schema = 'public' and column_name ilike '%phone%'),
  'no phone columns in public tables');
select tests.check(private.link_verified_phone(:bob, '12345') = 'invalid_phone', 'phone numbers must be E.164');

-- ---------------------------------------------------------------- sign-up hook throttling
select tests.check((select count(*) = 10 from generate_series(1, 10) g
  where public.hook_before_user_created('{"metadata": {"ip_address": "203.0.113.7"}, "user": {"email": "new@example.com"}}') = '{}'::jsonb),
  'sign-ups below the limit are allowed');
select tests.check((public.hook_before_user_created('{"metadata": {"ip_address": "203.0.113.7"}, "user": {"email": "new@example.com"}}')
  -> 'error' ->> 'http_code') = '429', 'repeated sign-ups from one source are throttled');
select tests.check((select count(*) = 0 from private.rate_limit_events where subject_key like '203.%'), 'IP addresses are stored hashed');
select tests.become('authenticated', :alice);
select tests.expect_error($$select public.hook_before_user_created('{}')$$, 'permission denied', 'users cannot call the auth hook');
select tests.become_admin();

-- ---------------------------------------------------------------- deletion does not reset safeguards
delete from auth.users where id = :alice;
select tests.check((select count(*) = 1 from private.account_tombstones where email_hash = private.hash_identifier('alice@example.com')),
  'deletion leaves a hashed tombstone');
select tests.check((select count(*) = 0 from private.account_tombstones where email_hash like '%alice%'), 'tombstone holds no plain email');
select tests.check((public.hook_before_user_created('{"metadata": {"ip_address": "198.51.100.1"}, "user": {"email": "Alice@Example.com"}}')
  -> 'error' ->> 'http_code') = '403', 'the same email cannot immediately create a new account');
insert into auth.users (id, email) values ('44444444-4444-4444-4444-444444444444', 'dave@example.com');
select tests.check(private.link_verified_phone('44444444-4444-4444-4444-444444444444', '+15551234567') = 'phone_recently_used',
  'a deleted account''s phone cannot be reused during the cooldown');
select tests.check((select count(*) = 1 from private.account_tombstones where :install is not null
  and private.hash_identifier(:install) = any (install_id_hashes)), 'tombstone remembers the hashed install');

-- After the cooldown the email may sign up again, but the new account is flagged
update private.account_tombstones set block_recreation_until = now() - interval '1 second';
select tests.check(public.hook_before_user_created('{"metadata": {"ip_address": "198.51.100.2"}, "user": {"email": "alice@example.com"}}') = '{}'::jsonb,
  'recreation is allowed after the cooldown');
insert into auth.users (id, email) values ('55555555-5555-5555-5555-555555555555', 'alice@example.com');
select tests.check((select count(*) = 1 from private.abuse_signals
  where user_id = '55555555-5555-5555-5555-555555555555' and signal_type = 'account_recreation'),
  'the recreated account is flagged for review');
select tests.check((select status = 'pending_verification' from private.accounts where user_id = '55555555-5555-5555-5555-555555555555'),
  'and is not automatically suspended');

-- Restricted accounts get the long cooldown
delete from auth.users where id = :bob;
select tests.check((select block_recreation_until > now() + interval '300 days' from private.account_tombstones
  where email_hash = private.hash_identifier('bob@example.com')), 'deleting a restricted account triggers the long cooldown');
