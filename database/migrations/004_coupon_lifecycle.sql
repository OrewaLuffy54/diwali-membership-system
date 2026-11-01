-- Coupon lifecycle and payment-approval hardening.
-- Additive only: all existing coupons, payments, members, and admin data are retained.

alter table coupon_codes
  alter column max_uses drop not null;

alter table coupon_codes
  add column if not exists updated_at timestamptz not null default now();

-- Preflight before validating legacy data:
-- select id, code, uses, max_uses from coupon_codes
-- where uses < 0 or max_uses <= 0;
-- NOT VALID preserves any historical anomalies while enforcing the rule for
-- future inserts/updates. Validate later only after an explicit data review.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.coupon_codes'::regclass
      and conname = 'coupon_codes_max_uses_positive_004'
  ) then
    execute 'alter table public.coupon_codes
      add constraint coupon_codes_max_uses_positive_004
      check (max_uses is null or max_uses > 0) not valid';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.coupon_codes'::regclass
      and conname = 'coupon_codes_uses_nonnegative_004'
  ) then
    execute 'alter table public.coupon_codes
      add constraint coupon_codes_uses_nonnegative_004
      check (uses >= 0) not valid';
  end if;
end;
$$;

create index if not exists coupon_codes_admin_list_idx
  on coupon_codes(created_at desc);

create table if not exists coupon_payment_usages (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references coupon_codes(id),
  payment_submission_id uuid not null references payment_submissions(id),
  used_at timestamptz not null default now(),
  unique (payment_submission_id),
  unique (coupon_id, payment_submission_id)
);

create index if not exists coupon_payment_usages_coupon_idx
  on coupon_payment_usages(coupon_id, used_at desc);
alter table coupon_payment_usages enable row level security;

-- The worker calls this function with the service role.  A single transaction:
-- locks the payment and coupon, rechecks eligibility, activates membership, marks
-- the payment approved, and records/increments coupon use exactly once.
create or replace function public.approve_payment_submission(p_submission_id uuid)
returns table(result text, expires_at timestamptz, error_message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment payment_submissions%rowtype;
  v_coupon coupon_codes%rowtype;
  v_account_id uuid;
  v_membership memberships%rowtype;
  v_start timestamptz;
  v_expiry timestamptz;
begin
  select * into v_payment
  from payment_submissions
  where id = p_submission_id
  for update;

  if not found then
    return query select 'not_found'::text, null::timestamptz, 'Submission not found'::text;
    return;
  end if;
  if v_payment.status <> 'pending' then
    return query select 'already_processed'::text, null::timestamptz, 'Payment has already been processed'::text;
    return;
  end if;

  if v_payment.coupon_code is not null then
    select * into v_coupon
    from coupon_codes
    where code = upper(v_payment.coupon_code)
    for update;

    if not found then
      return query select 'coupon_invalid'::text, null::timestamptz, 'Coupon no longer exists'::text;
      return;
    end if;
    if not v_coupon.active then
      return query select 'coupon_invalid'::text, null::timestamptz, 'Coupon is disabled'::text;
      return;
    end if;
    if v_coupon.expires_at is not null and v_coupon.expires_at <= now() then
      return query select 'coupon_invalid'::text, null::timestamptz, 'Coupon has expired'::text;
      return;
    end if;
    if v_coupon.max_uses is not null and v_coupon.uses >= v_coupon.max_uses then
      return query select 'coupon_invalid'::text, null::timestamptz, 'Coupon usage limit has been reached'::text;
      return;
    end if;
  end if;

  select id into v_account_id
  from minecraft_accounts
  where minecraft_username = v_payment.minecraft_username
  for update;

  if found then
    if (select user_id from minecraft_accounts where id = v_account_id) <> v_payment.user_id then
      raise exception 'Minecraft username belongs to another account';
    end if;
  else
    insert into minecraft_accounts(user_id, discord_id, minecraft_username)
    values (v_payment.user_id, v_payment.discord_id, v_payment.minecraft_username)
    returning id into v_account_id;
  end if;

  select * into v_membership
  from memberships
  where minecraft_account_id = v_account_id and status = 'active'
  order by expires_at desc
  limit 1
  for update;

  v_start := case when found and v_membership.expires_at > now() then v_membership.expires_at else now() end;
  v_expiry := v_start + make_interval(days => v_payment.duration_days);

  if found then
    update memberships
    set expires_at = v_expiry, status = 'active', reminder_sent = null
    where id = v_membership.id;
  else
    insert into memberships(user_id, minecraft_account_id, status, starts_at, expires_at)
    values (v_payment.user_id, v_account_id, 'active', now(), v_expiry);
  end if;

  insert into discord_accounts(user_id, discord_id)
  values (v_payment.user_id, v_payment.discord_id)
  on conflict (user_id) do update set discord_id = excluded.discord_id;

  if v_payment.coupon_code is not null then
    insert into coupon_payment_usages(coupon_id, payment_submission_id)
    values (v_coupon.id, v_payment.id);
    update coupon_codes set uses = uses + 1, updated_at = now() where id = v_coupon.id;
  end if;

  update payment_submissions
  set status = 'approved', reviewed_at = now()
  where id = v_payment.id;

  return query select 'approved'::text, v_expiry, null::text;
end;
$$;

revoke all on function public.approve_payment_submission(uuid) from public;
grant execute on function public.approve_payment_submission(uuid) to service_role;
