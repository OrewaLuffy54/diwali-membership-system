-- 007_minecraft_username_purchase_access.sql
-- Allow any authenticated Discord account to purchase membership for any
-- Minecraft username. Minecraft username remains globally unique; memberships
-- remain attached to that username. Existing rows are preserved.
-- The user_id/discord_id on minecraft_accounts and user_id on memberships are
-- purchaser/contact metadata, updated to the latest successful purchaser.

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

  -- Lock the username row, creating it only when it does not exist.
  loop
    select id into v_account_id
    from minecraft_accounts
    where lower(minecraft_username) = lower(v_payment.minecraft_username)
    for update;
    exit when found;

    insert into minecraft_accounts(user_id, discord_id, minecraft_username)
    values (v_payment.user_id, v_payment.discord_id, v_payment.minecraft_username)
    on conflict (minecraft_username) do nothing
    returning id into v_account_id;
    exit when found;
  end loop;

  -- This is purchaser/contact metadata, not an ownership restriction.
  update minecraft_accounts
  set user_id = v_payment.user_id, discord_id = v_payment.discord_id
  where id = v_account_id;

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
    set user_id = v_payment.user_id,
        expires_at = v_expiry,
        status = 'active',
        reminder_sent = null
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

create or replace function public.redeem_gift_code(
  p_code text,
  p_minecraft_username text,
  p_user_id uuid,
  p_discord_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code redeem_codes%rowtype;
  v_account_id uuid;
  v_membership memberships%rowtype;
  v_has_membership boolean := false;
  v_now timestamptz := now();
  v_start timestamptz;
  v_expiry timestamptz;
begin
  if p_user_id is null
     or coalesce(trim(p_discord_id), '') = ''
     or trim(coalesce(p_minecraft_username, '')) !~ '^[A-Za-z0-9_]{3,16}$'
     or trim(coalesce(p_code, '')) = '' then
    return jsonb_build_object('result','invalid_input',
      'error_message','Enter a valid gift code and Minecraft username');
  end if;

  select * into v_code
  from redeem_codes
  where code = upper(trim(p_code)) and code_type = 'gift'
  for update;

  if not found or not v_code.active then
    return jsonb_build_object('result','invalid_code',
      'error_message','Gift code is invalid or disabled');
  end if;
  if v_code.expires_at is not null and v_code.expires_at <= v_now then
    return jsonb_build_object('result','expired','error_message','Gift code has expired');
  end if;
  if v_code.uses >= v_code.max_uses then
    return jsonb_build_object('result','exhausted','error_message','Gift code usage limit reached');
  end if;
  if exists (select 1 from redemptions where code_id = v_code.id and user_id = p_user_id) then
    return jsonb_build_object('result','already_redeemed',
      'error_message','This account already redeemed this gift code');
  end if;

  loop
    select id into v_account_id
    from minecraft_accounts
    where lower(minecraft_username) = lower(trim(p_minecraft_username))
    for update;
    exit when found;

    begin
      insert into minecraft_accounts(user_id, discord_id, minecraft_username)
      values (p_user_id, trim(p_discord_id), trim(p_minecraft_username))
      returning id into v_account_id;
      exit;
    exception when unique_violation then
      null;
    end;
  end loop;

  -- No owner check: username is the membership target, not a Discord-linked identity.
  update minecraft_accounts
  set user_id = p_user_id, discord_id = trim(p_discord_id)
  where id = v_account_id;

  select * into v_membership
  from memberships
  where minecraft_account_id = v_account_id and status = 'active'
  order by expires_at desc
  limit 1
  for update;

  v_has_membership := found;
  v_start := case
    when v_has_membership and v_membership.expires_at > v_now then v_membership.expires_at
    else v_now
  end;
  v_expiry := v_start + make_interval(days => v_code.duration_days);

  insert into redemptions(code_id, user_id, minecraft_username)
  values (v_code.id, p_user_id, trim(p_minecraft_username));

  update redeem_codes set uses = uses + 1 where id = v_code.id;

  if v_has_membership then
    update memberships
    set user_id = p_user_id, expires_at = v_expiry,
        status = 'active', reminder_sent = null
    where id = v_membership.id;
  else
    insert into memberships(user_id, minecraft_account_id, status, starts_at, expires_at)
    values (p_user_id, v_account_id, 'active', v_now, v_expiry);
  end if;

  insert into discord_accounts(user_id, discord_id)
  values (p_user_id, trim(p_discord_id))
  on conflict (user_id) do update set discord_id = excluded.discord_id;

  return jsonb_build_object('result','redeemed','expires_at',v_expiry,
    'duration_days',v_code.duration_days,'error_message',null);
end;
$$;

revoke all on function public.approve_payment_submission(uuid) from public;
grant execute on function public.approve_payment_submission(uuid) to service_role;
revoke all on function public.redeem_gift_code(text,text,uuid,text) from public;
revoke all on function public.redeem_gift_code(text,text,uuid,text) from anon;
revoke all on function public.redeem_gift_code(text,text,uuid,text) from authenticated;
grant execute on function public.redeem_gift_code(text,text,uuid,text) to service_role;
