-- public.profiles: RLS, grants, validation, server-side completion.

\set alice '''11111111-1111-1111-1111-111111111111'''
\set bob '''22222222-2222-2222-2222-222222222222'''

-- Anonymous: no access
select tests.become('anon');
select tests.expect_error('select * from public.profiles', 'permission denied', 'anon cannot read profiles');
select tests.expect_error($$insert into public.profiles (display_name) values ('x')$$, 'permission denied', 'anon cannot create profiles');
select tests.expect_error('select * from public.gender_options', 'permission denied', 'anon cannot read lookups');
select tests.become_admin();

-- Alice
select tests.become('authenticated', :alice);
select tests.expect_error($$insert into public.profiles (id, display_name) values ('22222222-2222-2222-2222-222222222222', 'Mallory')$$,
  'row-level security', 'cannot create a profile for someone else');
select tests.expect_error($$insert into public.profiles (profile_completed) values (true)$$,
  'permission denied', 'cannot set profile_completed');
select tests.expect_error($$insert into public.profiles (verification_status) values ('verified')$$,
  'permission denied', 'cannot insert a verified status');
select tests.expect_error($$insert into public.profiles (display_name, birth_date) values ('A', (now() at time zone 'utc')::date + 1)$$,
  'birth_date_in_future', 'future birth date rejected');
select tests.expect_error($$insert into public.profiles (display_name, birth_date) values ('A', ((now() at time zone 'utc')::date - interval '18 years' + interval '1 day')::date)$$,
  'under_minimum_age', 'under 18 rejected');
select tests.expect_error($$insert into public.profiles (display_name) values (' A')$$, 'check', 'untrimmed name rejected');
select tests.expect_error($$insert into public.profiles (community_identity, dating_preference) values ('goth', 'normie_seeking_goth')$$,
  'foreign key', 'preference must match identity');
select tests.expect_error($$insert into public.profiles (gender) values ('not_a_gender')$$, 'foreign key', 'unknown gender rejected');

insert into public.profiles (display_name, birth_date)
values ('Raven', ((now() at time zone 'utc')::date - interval '18 years')::date);
select tests.check((select not profile_completed and verification_status = 'not_started' from public.profiles),
  'partial profile saved, incomplete, verification not started');

select tests.expect_error('update public.profiles set profile_completed = true', 'permission denied', 'cannot force completion');
select tests.expect_error($$update public.profiles set verification_status = 'verified'$$, 'permission denied', 'cannot set verification_status');
select tests.expect_error('update public.profiles set verification_reviewed_at = now()', 'permission denied', 'cannot set reviewed timestamp');
select tests.expect_error('update public.profiles set verified_badge = true', 'verified_badge', 'cannot write the verified badge');
select tests.expect_error($$update public.profiles set id = '22222222-2222-2222-2222-222222222222'$$, 'permission denied', 'cannot change id');

update public.profiles set
  location_city = 'Salem', location_state_or_region = 'Massachusetts',
  gender = 'self_describe', gender_self_description = 'Moth-adjacent',
  community_identity = 'goth', dating_preference = 'goth_seeking_normie',
  bio = E'Crypt keeper.\nFog, velvet & rain!';
select tests.check((select profile_completed from public.profiles), 'server marks a full profile complete');
select tests.check((select not verified_badge from public.profiles), 'complete profile has no verified badge');
select tests.become_admin();

-- Bob cannot see or change Alice
select tests.become('authenticated', :bob);
select tests.check((select count(*) = 0 from public.profiles), 'bob cannot see alice');
update public.profiles set display_name = 'Hacked' where id = '11111111-1111-1111-1111-111111111111';
select tests.expect_error('delete from public.profiles', 'permission denied', 'no deletes via the API');
select tests.become_admin();
select tests.check((select display_name = 'Raven' from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'alice unchanged after bob''s update attempt');

-- Trigger guard: even with an accidental grant, clients can't verify themselves
grant update (verification_status) on public.profiles to authenticated;
select tests.become('authenticated', :alice);
update public.profiles set verification_status = 'verified';
select tests.become_admin();
select tests.check((select verification_status = 'not_started' from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'trigger ignores client-written verification status');
revoke update (verification_status) on public.profiles from authenticated;
