-- Diwali Network: Discord-ID based custom admin permissions.
-- Additive and safe to re-run. Does not drop or reset existing membership data.
create table if not exists admin_roles (
  discord_id text primary key check (discord_id ~ '^[0-9]{17,20}$'),
  role text not null default 'custom' check (role in ('admin','moderator','support','payment_manager','membership_manager','coupon_manager','custom')),
  permissions jsonb not null default '[]'::jsonb check (jsonb_typeof(permissions) = 'array'),
  active boolean not null default true,
  granted_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_discord_id text not null,
  action text not null,
  target_discord_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists admin_audit_logs_created_idx on admin_audit_logs(created_at desc);
create index if not exists admin_audit_logs_actor_idx on admin_audit_logs(actor_discord_id, created_at desc);
alter table admin_roles enable row level security;
alter table admin_audit_logs enable row level security;
-- The Cloudflare Worker accesses these tables with the service role only.
-- Owner is seeded from the configured Discord ID. Worker also enforces this ID as owner.
insert into admin_roles(discord_id, role, permissions, active, granted_by)
values ('1013832671014699130','admin','["*"]'::jsonb,true,'system')
on conflict (discord_id) do update set role='admin', permissions='["*"]'::jsonb, active=true;
