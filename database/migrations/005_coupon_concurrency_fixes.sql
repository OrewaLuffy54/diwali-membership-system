-- Coupon concurrency safeguards. Additive: retains all existing records.
-- Apply only after 004_coupon_lifecycle.sql.

-- Preflight only: do not resolve duplicates automatically. If this check fails,
-- no coupon, payment, or membership records are changed by the statements below.
do $$
begin
  if exists (
    select 1
    from coupon_codes
    group by upper(code)
    having count(*) > 1
  ) then
    raise exception 'Case-insensitive duplicate coupon codes exist; resolve them manually before applying 005';
  end if;
end;
$$;

-- Retain the displayed code verbatim while using this generated canonical value
-- for all coupon identity comparisons. Existing coupon rows are not rewritten.
alter table coupon_codes
  add column if not exists code_normalized text
  generated always as (upper(code)) stored;

create unique index if not exists coupon_codes_code_normalized_uidx
  on coupon_codes(code_normalized);

-- minecraft_username is unique in the baseline schema. This preflight keeps
-- ON CONFLICT (minecraft_username) valid on legacy installations as well.
do $$
declare
  v_username_attnum smallint;
begin
  select attnum into v_username_attnum
  from pg_attribute
  where attrelid = 'public.minecraft_accounts'::regclass
    and attname = 'minecraft_username'
    and not attisdropped;

  if not found then
    raise exception 'minecraft_accounts.minecraft_username is missing';
  end if;

  if exists (
    select 1 from minecraft_accounts
    group by minecraft_username
    having count(*) > 1
  ) then
    raise exception 'Duplicate minecraft usernames exist; resolve them manually before applying 005';
  end if;

  if not exists (
    select 1
    from pg_index i
    where i.indrelid = 'public.minecraft_accounts'::regclass
      and i.indisunique
      and i.indisvalid
      and i.indpred is null
      and i.indexprs is null
      and i.indnkeyatts = 1
      and i.indkey[0] = v_username_attnum
  ) then
    execute 'alter table public.minecraft_accounts
      add constraint minecraft_accounts_minecraft_username_unique_005
      unique (minecraft_username)';
  end if;
end;
$$;

-- Prevent all application activation paths from creating a second active
-- membership. The preflight stops rather than modifies legacy duplicate rows.
do $$
begin
  if exists (
    select 1 from memberships
    where status = 'active'
    group by minecraft_account_id
    having count(*) > 1
  ) then
    raise exception 'Multiple active memberships exist for at least one Minecraft account; resolve them manually before applying 005';
  end if;
end;
$$;

create unique index if not exists memberships_one_active_per_account_uidx
  on memberships(minecraft_account_id)
  where status = 'active';

create index if not exists payment_submissions_coupon_code_upper_idx
  on payment_submissions (upper(coupon_code))
  where coupon_code is not null;

-- Every new payment reference takes the same transaction-level lock used by
-- deletion and code rename. This closes the check-then-delete race even though
-- legacy payment_submissions stores a coupon code rather than a foreign key.
create or replace function public.guard_payment_coupon_reference()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.coupon_code is null then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('coupon:' || upper(new.coupon_code), 0)
  );

  if not exists (
    select 1 from coupon_codes
    where code_normalized = upper(new.coupon_code)
  ) then
    raise exception 'Coupon no longer exists';
  end if;

  return new;
end;
$$;

drop trigger if exists payment_coupon_reference_guard on payment_submissions;
create trigger payment_coupon_reference_guard
before insert or update of coupon_code on payment_submissions
for each row execute function public.guard_payment_coupon_reference();

-- A code stored on a payment is part of that payment's approval record. Do not
-- let an edit orphan pending or historical payment references.
create or replace function public.prevent_referenced_coupon_rename()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.code is not distinct from old.code then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('coupon:' || old.code_normalized, 0)
  );

  if exists (
    select 1 from payment_submissions
    where upper(coupon_code) = old.code_normalized
  ) then
    raise exception 'A coupon code cannot be renamed after a payment references it';
  end if;

  return new;
end;
$$;

drop trigger if exists coupon_rename_reference_guard on coupon_codes;
create trigger coupon_rename_reference_guard
before update of code on coupon_codes
for each row execute function public.prevent_referenced_coupon_rename();

-- Delete only an unused coupon with no usage record and no payment reference.
-- The advisory lock serializes the check with the payment-reference trigger.
create or replace function public.delete_coupon_if_safe(p_coupon_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon coupon_codes%rowtype;
begin
  select * into v_coupon
  from coupon_codes
  where id = p_coupon_id
  for update;

  if not found then
    return false;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('coupon:' || v_coupon.code_normalized, 0)
  );

  if v_coupon.uses <> 0
     or exists (select 1 from coupon_payment_usages where coupon_id = v_coupon.id)
     or exists (
       select 1 from payment_submissions
       where upper(coupon_code) = v_coupon.code_normalized
     ) then
    return false;
  end if;

  delete from coupon_codes where id = v_coupon.id;
  return true;
end;
$$;

-- Same signature and result contract as 004, with account-row serialization.
-- It never updates an account owned by somebody else.
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
  v_account_user_id uuid;
  v_membership memberships%rowtype;
  v_has_membership boolean := false;
  v_expiry timestamptz;
  v_usage_id uuid;
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
    where code_normalized = upper(v_payment.coupon_code)
    for update;

    if not found or not v_coupon.active
       or (v_coupon.expires_at is not null and v_coupon.expires_at <= now())
       or (v_coupon.max_uses is not null and v_coupon.uses >= v_coupon.max_uses) then
      return query select 'coupon_invalid'::text, null::timestamptz,
        'Coupon is disabled, expired, exhausted, or no longer exists'::text;
      return;
    end if;
  end if;

  -- Loop only when another transaction is concurrently creating this account.
  -- FOR UPDATE serializes membership activation for existing accounts too.
  loop
    select id, user_id into v_account_id, v_account_user_id
    from minecraft_accounts
    where minecraft_username = v_payment.minecraft_username
    for update;
    exit when found;

    insert into minecraft_accounts(user_id, discord_id, minecraft_username)
    values (v_payment.user_id, v_payment.discord_id, v_payment.minecraft_username)
    on conflict (minecraft_username) do nothing
    returning id, user_id into v_account_id, v_account_user_id;
    exit when found;
  end loop;

  if v_account_user_id <> v_payment.user_id then
    raise exception 'Minecraft username belongs to another account';
  end if;

  select * into v_membership
  from memberships
  where minecraft_account_id = v_account_id and status = 'active'
  order by expires_at desc
  limit 1
  for update;

  v_has_membership := found;
  v_expiry := case
    when v_has_membership and v_membership.expires_at > now() then v_membership.expires_at
    else now()
  end + make_interval(days => v_payment.duration_days);

  if v_has_membership then
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
    values (v_coupon.id, v_payment.id)
    on conflict (payment_submission_id) do nothing
    returning id into v_usage_id;

    if not found then
      raise exception 'Coupon usage already recorded for this payment';
    end if;

    update coupon_codes
    set uses = uses + 1, updated_at = now()
    where id = v_coupon.id;
  end if;

  update payment_submissions
  set status = 'approved', reviewed_at = now()
  where id = v_payment.id;

  return query select 'approved'::text, v_expiry, null::text;
end;
$$;

revoke all on function public.delete_coupon_if_safe(uuid) from public;
revoke all on function public.approve_payment_submission(uuid) from public;
grant execute on function public.delete_coupon_if_safe(uuid) to service_role;
grant execute on function public.approve_payment_submission(uuid) to service_role;
