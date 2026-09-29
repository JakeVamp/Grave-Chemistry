-- Minimal stand-in for the parts of Supabase the migrations depend on, so
-- they can be tested on a plain local PostgreSQL. Not used in production.

do $$
declare
  r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'supabase_auth_admin'] loop
    if not exists (select from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
    end if;
  end loop;
end $$;

create schema if not exists extensions;

-- auth
create schema auth;
create table auth.users (
  id uuid primary key,
  email text unique,
  phone text unique,
  email_confirmed_at timestamptz,
  created_at timestamptz default now()
);
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on all functions in schema auth to anon, authenticated, service_role;

-- storage (as in Supabase: API roles have table grants; RLS decides)
create schema storage;
create table storage.buckets (
  id text primary key,
  name text not null,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text not null,
  owner_id text,
  created_at timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated, service_role;

-- A project with automatic table exposure disabled has no default grants,
-- but API roles can use the public schema.
grant usage on schema public to anon, authenticated, service_role;
