create extension if not exists pgcrypto;

create table if not exists minecraft_accounts(
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null,
 discord_id text not null,
 minecraft_username text not null unique,
 created_at timestamptz not null default now()
);
create table if not exists memberships(
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null,
 minecraft_account_id uuid not null references minecraft_accounts(id),
 status text not null check(status in ('active','expired','cancelled')),
 starts_at timestamptz not null,
 expires_at timestamptz not null,
 reminder_sent timestamptz,
 created_at timestamptz not null default now()
);
create table if not exists subscription_plans(
 id text primary key,
 name text not null,
 duration_days integer not null check(duration_days between 1 and 3650),
 price_paise integer not null check(price_paise >= 0),
 active boolean not null default true,
 sort_order integer not null default 0,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
insert into subscription_plans(id,name,duration_days,price_paise,sort_order) values
 ('monthly','Monthly',30,5000,1),('quarterly','Quarterly',90,15000,2),
 ('half-yearly','Half Yearly',180,30000,3),('yearly','Yearly',365,60000,4)
on conflict(id) do nothing;

create table if not exists payment_submissions(
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null,
 discord_id text not null,
 minecraft_username text not null,
 utr text not null unique,
 amount_paise integer not null check(amount_paise >= 0),
 plan_id text references subscription_plans(id),
 duration_days integer not null default 30 check(duration_days between 1 and 3650),
 coupon_code text,
 status text not null check(status in ('pending','approved','rejected')),
 created_at timestamptz not null default now(),
 reviewed_at timestamptz
);
-- Upgrade path for an existing MVP database (safe to re-run).
alter table payment_submissions add column if not exists plan_id text;
alter table payment_submissions add column if not exists duration_days integer not null default 30;
alter table payment_submissions add column if not exists coupon_code text;
alter table payment_submissions drop constraint if exists payment_submissions_amount_paise_check;
alter table payment_submissions add constraint payment_submissions_amount_paise_check check(amount_paise >= 0);
alter table payment_submissions drop constraint if exists payment_submissions_duration_days_check;
alter table payment_submissions add constraint payment_submissions_duration_days_check check(duration_days between 1 and 3650);

create table if not exists discord_accounts(
 user_id uuid primary key,
 discord_id text not null unique,
 linked_at timestamptz not null default now()
);
create table if not exists redeem_codes(
 id uuid primary key default gen_random_uuid(),
 code text not null unique,
 duration_days integer not null check(duration_days between 1 and 3650),
 code_type text not null check(code_type in ('gift','promo')),
 discount_type text check(discount_type in ('percent','fixed')),
 discount_value integer,
 max_uses integer not null default 1,
 uses integer not null default 0,
 expires_at timestamptz,
 active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists redemptions(
 id uuid primary key default gen_random_uuid(),
 code_id uuid not null references redeem_codes(id),
 user_id uuid not null,
 minecraft_username text not null,
 redeemed_at timestamptz not null default now(),
 unique(code_id,user_id)
);
create table if not exists coupon_codes(
 id uuid primary key default gen_random_uuid(),
 code text not null unique,
 discount_type text not null check(discount_type in ('percent','fixed')),
 discount_value integer not null check(discount_value > 0),
 max_uses integer not null default 100,
 uses integer not null default 0,
 expires_at timestamptz,
 active boolean not null default true,
 created_at timestamptz not null default now()
);
create index if not exists memberships_expiry_idx on memberships(status,expires_at);
create index if not exists submissions_status_idx on payment_submissions(status,created_at);
create index if not exists redeem_codes_lookup_idx on redeem_codes(code,active);
alter table minecraft_accounts enable row level security;
alter table memberships enable row level security;
alter table payment_submissions enable row level security;
alter table discord_accounts enable row level security;
alter table subscription_plans enable row level security;
alter table redeem_codes enable row level security;
alter table redemptions enable row level security;
alter table coupon_codes enable row level security;
-- All privileged reads/writes are performed by the Cloudflare Worker service role.
