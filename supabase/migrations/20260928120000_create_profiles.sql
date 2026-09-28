-- Grave Chemistry: user profiles (onboarding foundation)
--
-- Creates:
--   * Lookup tables for community identities, dating preferences and gender
--     options. New values are added by inserting rows, and values can be
--     retired with is_active = false, so no destructive migration is needed.
--   * public.profiles: one row per auth user, owner-only access via RLS.
--   * A trigger that maintains timestamps and computes profile_completed on
--     the server. Clients can never set profile_completed themselves.
--
-- Discovery (other users seeing a profile) is intentionally NOT enabled.
-- It should be added later as a separate view or function that exposes only
-- public fields and a computed age, never birth_date.

-- ---------------------------------------------------------------------------
-- Lookup tables
-- ---------------------------------------------------------------------------

create table public.community_identities (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]{0,39}$'),
  label       text not null check (char_length(label) between 1 and 60),
  sort_order  smallint not null default 0,
  is_active   boolean not null default true
);

comment on table public.community_identities is
  'Allowed community identities. Add rows to extend; set is_active = false to retire.';

insert into public.community_identities (code, label, sort_order) values
  ('goth',   'Goth',   10),
  ('normie', 'Normie', 20);

create table public.dating_preferences (
  code             text primary key check (code ~ '^[a-z][a-z0-9_]{0,59}$'),
  seeker_identity  text not null references public.community_identities (code),
  sought_identity  text not null references public.community_identities (code),
  label            text not null check (char_length(label) between 1 and 80),
  sort_order       smallint not null default 0,
  is_active        boolean not null default true,
  unique (seeker_identity, sought_identity),
  -- Target of the composite foreign key on profiles, which guarantees a
  -- profile's preference matches its own community identity.
  unique (code, seeker_identity)
);

comment on table public.dating_preferences is
  'Allowed dating preferences as (seeker, sought) identity pairs. Add rows to extend.';

insert into public.dating_preferences
  (code, seeker_identity, sought_identity, label, sort_order) values
  ('goth_seeking_goth',   'goth',   'goth',   'Goth seeking Goth',   10),
  ('normie_seeking_goth', 'normie', 'goth',   'Normie seeking Goth', 20),
  ('goth_seeking_normie', 'goth',   'normie', 'Goth seeking Normie', 30);

create table public.gender_options (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]{0,39}$'),
  label       text not null check (char_length(label) between 1 and 60),
  sort_order  smallint not null default 0,
  is_active   boolean not null default true
);

comment on table public.gender_options is
  'Selectable gender identities. Not a fixed binary; add rows to extend. '
  '"self_describe" pairs with profiles.gender_self_description.';

insert into public.gender_options (code, label, sort_order) values
  ('woman',         'Woman',         10),
  ('man',           'Man',           20),
  ('non_binary',    'Non-binary',    30),
  ('trans_woman',   'Trans woman',   40),
  ('trans_man',     'Trans man',     50),
  ('genderqueer',   'Genderqueer',   60),
  ('genderfluid',   'Genderfluid',   70),
  ('agender',       'Agender',       80),
  ('self_describe', 'Self-describe', 90);

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------

-- Onboarding fields are nullable so a profile can exist before it is
-- finished. When a value is present it must be valid; profile_completed says
-- whether every required field is present.
create table public.profiles (
  id uuid primary key default auth.uid()
    references auth.users (id) on delete cascade,

  display_name text
    check (
      char_length(display_name) between 1 and 50
      and display_name = btrim(display_name)
      and display_name !~ '[[:cntrl:]]'
    ),

  -- Owner-only. Other users must only ever see a computed age.
  birth_date date
    check (birth_date >= date '1900-01-01'),

  location_city text
    check (
      char_length(location_city) between 1 and 100
      and location_city = btrim(location_city)
      and location_city !~ '[[:cntrl:]]'
    ),

  location_state_or_region text
    check (
      char_length(location_state_or_region) between 1 and 100
      and location_state_or_region = btrim(location_state_or_region)
      and location_state_or_region !~ '[[:cntrl:]]'
    ),

  -- Line breaks and punctuation are allowed.
  bio text
    check (char_length(bio) between 1 and 500),

  gender text references public.gender_options (code),

  gender_self_description text
    check (
      char_length(gender_self_description) between 1 and 50
      and gender_self_description = btrim(gender_self_description)
      and gender_self_description !~ '[[:cntrl:]]'
    ),

  community_identity text references public.community_identities (code),

  dating_preference text,

  -- Computed by trigger; never writable by clients.
  profile_completed boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint profiles_self_description_requires_self_describe
    check (gender_self_description is null or gender = 'self_describe'),

  -- The chosen preference must start from the user's own identity
  -- (e.g. a goth cannot pick "normie seeking goth").
  constraint profiles_dating_preference_matches_identity
    foreign key (dating_preference, community_identity)
    references public.dating_preferences (code, seeker_identity)
);

comment on table public.profiles is
  'One profile per auth user. Email and password stay in auth.users.';
comment on column public.profiles.profile_completed is
  'Set by the profiles_before_write trigger; client values are ignored.';

-- Supports lookups by preference and future discovery queries over
-- completed profiles.
create index profiles_completed_identity_preference_idx
  on public.profiles (community_identity, dating_preference)
  where profile_completed;

create index profiles_gender_idx on public.profiles (gender);

-- ---------------------------------------------------------------------------
-- Trigger: timestamps, age rules, server-side completion
-- ---------------------------------------------------------------------------

create function public.profiles_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  minimum_age constant integer := 18;
  today_utc constant date := (now() at time zone 'utc')::date;
begin
  if tg_op = 'UPDATE' then
    new.id := old.id;
    new.created_at := old.created_at;
  else
    new.created_at := now();
  end if;
  new.updated_at := now();

  if new.birth_date is not null then
    if new.birth_date > today_utc then
      raise exception using
        errcode = 'check_violation',
        message = 'birth_date_in_future',
        detail = 'Birth date cannot be in the future.';
    end if;

    if extract(year from age(today_utc, new.birth_date)) < minimum_age then
      raise exception using
        errcode = 'check_violation',
        message = 'under_minimum_age',
        detail = format('Users must be at least %s years old.', minimum_age);
    end if;
  end if;

  -- Column CHECK constraints guarantee each present value is valid, so
  -- completion only needs every required value to be present.
  new.profile_completed :=
        new.display_name is not null
    and new.birth_date is not null
    and new.location_city is not null
    and new.location_state_or_region is not null
    and new.gender is not null
    and (new.gender <> 'self_describe' or new.gender_self_description is not null)
    and new.community_identity is not null
    and new.dating_preference is not null;

  return new;
end;
$$;

create trigger profiles_before_write
  before insert or update on public.profiles
  for each row execute function public.profiles_before_write();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.community_identities enable row level security;
alter table public.dating_preferences enable row level security;
alter table public.gender_options enable row level security;

create policy "Users can read their own profile"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "Users can create their own profile"
  on public.profiles for insert
  to authenticated
  with check ((select auth.uid()) = id);

create policy "Users can update their own profile"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- No delete policy: profiles are removed with the auth user (on delete
-- cascade). Account deletion will be designed separately.

create policy "Signed-in users can read community identities"
  on public.community_identities for select
  to authenticated
  using (true);

create policy "Signed-in users can read dating preferences"
  on public.dating_preferences for select
  to authenticated
  using (true);

create policy "Signed-in users can read gender options"
  on public.gender_options for select
  to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
-- Automatic table exposure is disabled for this project, so API access is
-- granted explicitly. Column-level grants mean clients can only write the
-- onboarding fields: never profile_completed or the timestamps, and never
-- id on update.

revoke all on public.profiles from anon, authenticated;
revoke all on public.community_identities from anon, authenticated;
revoke all on public.dating_preferences from anon, authenticated;
revoke all on public.gender_options from anon, authenticated;

grant select on public.profiles to authenticated;

grant insert (
  id,
  display_name,
  birth_date,
  location_city,
  location_state_or_region,
  bio,
  gender,
  gender_self_description,
  community_identity,
  dating_preference
) on public.profiles to authenticated;

grant update (
  display_name,
  birth_date,
  location_city,
  location_state_or_region,
  bio,
  gender,
  gender_self_description,
  community_identity,
  dating_preference
) on public.profiles to authenticated;

grant select on public.community_identities to authenticated;
grant select on public.dating_preferences to authenticated;
grant select on public.gender_options to authenticated;

-- Only the trigger calls this function.
revoke execute on function public.profiles_before_write() from public, anon, authenticated;
