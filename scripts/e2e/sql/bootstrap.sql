-- The parts of a Supabase project the HyperVault migrations assume are already
-- there: roles, the auth and extensions schemas, default privileges, and a
-- stand-in for pgvector's distance operators over real[].
--
-- Run once per fresh database, before the migrations. Throwaway local use only.

-- ── roles ───────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    create role supabase_admin nologin;
  end if;
end $$;

grant anon, authenticated, service_role to authenticator;
grant anon, authenticated, service_role to postgres;

-- ── schemas ─────────────────────────────────────────────────────────────────
create schema if not exists auth;
create schema if not exists extensions;
create schema if not exists storage;

grant usage on schema public, extensions to anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema storage to anon, authenticated, service_role;

do $$
begin
  execute format('alter database %I set search_path = "$user", public, extensions', current_database());
  execute format('alter database %I set timezone = %L', current_database(), 'UTC');
end $$;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists citext with schema extensions;

-- What Supabase configures for the postgres role in `public`: every new table,
-- sequence and function is reachable by the three API roles, and row level
-- security (or a later revoke in a migration) narrows it from there.
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all functions in schema public to anon, authenticated, service_role;
alter default privileges for role postgres in schema extensions grant execute on functions to anon, authenticated, service_role;

-- ── auth schema ─────────────────────────────────────────────────────────────
create table if not exists auth.users (
  instance_id uuid,
  id uuid primary key default gen_random_uuid(),
  aud varchar(255) default 'authenticated',
  role varchar(255) default 'authenticated',
  email varchar(255) unique,
  encrypted_password varchar(255),
  email_confirmed_at timestamptz,
  invited_at timestamptz,
  confirmation_token varchar(255),
  confirmation_sent_at timestamptz,
  recovery_token varchar(255),
  recovery_sent_at timestamptz,
  last_sign_in_at timestamptz,
  raw_app_meta_data jsonb default '{"provider":"email","providers":["email"]}'::jsonb,
  raw_user_meta_data jsonb default '{}'::jsonb,
  is_super_admin boolean,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  phone text unique,
  phone_confirmed_at timestamptz,
  banned_until timestamptz,
  deleted_at timestamptz,
  is_anonymous boolean not null default false
);

create or replace function auth.uid() returns uuid
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function auth.email() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$$;

create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

grant execute on all functions in schema auth to anon, authenticated, service_role;

-- ── storage schema (tables only; the files themselves are the stand-in's) ──
create table if not exists storage.buckets (
  id text primary key,
  name text not null unique,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text,
  owner uuid,
  metadata jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;

-- ── pgvector stand-in: vector(N) is real[]; distances are plain SQL ────────
create or replace function extensions.cosine_distance(a real[], b real[]) returns double precision
language sql immutable parallel safe as $$
  select 1 - coalesce(sum(x::double precision * y) / nullif(sqrt(sum(x::double precision * x)) * sqrt(sum(y::double precision * y)), 0), 0)
  from unnest(a, b) as t(x, y)
$$;
create or replace function extensions.l2_distance(a real[], b real[]) returns double precision
language sql immutable parallel safe as $$
  select sqrt(coalesce(sum((x::double precision - y) * (x::double precision - y)), 0)) from unnest(a, b) as t(x, y)
$$;
create or replace function extensions.inner_product(a real[], b real[]) returns double precision
language sql immutable parallel safe as $$
  select coalesce(sum(x::double precision * y), 0) from unnest(a, b) as t(x, y)
$$;
create or replace function extensions.negative_inner_product(a real[], b real[]) returns double precision
language sql immutable parallel safe as $$ select -extensions.inner_product(a, b) $$;
create or replace function extensions.vector_dims(a real[]) returns integer
language sql immutable parallel safe as $$ select coalesce(array_length(a, 1), 0) $$;
create or replace function extensions.l2_norm(a real[]) returns double precision
language sql immutable parallel safe as $$ select sqrt(coalesce(sum(x::double precision * x), 0)) from unnest(a) as t(x) $$;

create operator extensions.<=> (leftarg = real[], rightarg = real[], function = extensions.cosine_distance);
create operator extensions.<-> (leftarg = real[], rightarg = real[], function = extensions.l2_distance);
create operator extensions.<#> (leftarg = real[], rightarg = real[], function = extensions.negative_inner_product);
