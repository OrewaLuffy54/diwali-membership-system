-- 006_gift_redemption_atomic.sql
-- Atomic gift-code redemption + membership activation.
-- Additive migration. No tables are created and no existing records are deleted.
-- This version returns JSONB (not RETURNS TABLE) to avoid Supabase's misleading
-- "table without RLS" warning for a table-valued function.

-- Preflight: stop if case-insensitive Minecraft usernames already collide.
do $$
begin
  if exists (
    select 1
    from public.minecraft_accounts
    group by lower(minecraft_username)
    having count(*) > 1
  ) then
    raise exception
      'Case-insensitive duplicate Minecraft usernames exist; resolve them manually before applying 006';
  end if;
end;
$$;

-- Keep the existing exact-case unique index and add case-insensitive protection.
create unique index if not exists minecraft_accounts_username_lower_uidx
  on public.minecraft_accounts (lower(minecraft_username));

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
  v_code public.redeem_codes%rowtype;
  v_account_id uuid;
  v_account_user_id uuid;
  v_membership public.memberships%rowtype;
  v_has_membership boolean := false;
  v_now timestamptz := now();
  v_start timestamptz;
  v_expiry timestamptz;
begin
  if p_user_id is null
     or coalesce(trim(p_discord_id), '') = ''
     or trim(coalesce(p_minecraft_username, '')) !~ '^[A-Za-z0-9_]{3,16}$'
     or trim(coalesce(p_code, '')) = '' then
    return jsonb_build_object(
      'result', 'invalid_input',
      'error_message', 'Enter a valid gift code and Minecraft username'
    );
  end if;

  -- Lock the gift code row: simultaneous requests cannot exceed max_uses.
  select * into v_code
  from public.redeem_codes
  where code = upper(trim(p_code))
    and code_type = 'gift'
  for update;

  if not found or not v_code.active then
    return jsonb_build_object(
      'result', 'invalid_code',
      'error_message', 'Gift code is invalid or disabled'
    );
  end if;

  if v_code.expires_at is not null and v_code.expires_at <= v_now then
    return jsonb_build_object(
      'result', 'expired',
      'error_message', 'Gift code has expired'
    );
  end if;

  if v_code.uses >= v_code.max_uses then
    return jsonb_build_object(
      'result', 'exhausted',
      'error_message', 'Gift code usage limit reached'
    );
  end if;

  if exists (
    select 1 from public.redemptions
    where code_id = v_code.id and user_id = p_user_id
  ) then
    return jsonb_build_object(
      'result', 'already_redeemed',
      'error_message', 'This account already redeemed this gift code'
    );
  end if;

  -- Lock an existing account, or create it. A concurrent username insert
  -- is handled by the unique lower(username) index and this retry loop.
  loop
    select id, user_id
      into v_account_id, v_account_user_id
    from public.minecraft_accounts
    where lower(minecraft_username) = lower(trim(p_minecraft_username))
    for update;

    exit when found;

    begin
      insert into public.minecraft_accounts (
        user_id, discord_id, minecraft_username
      )
      values (
        p_user_id, trim(p_discord_id), trim(p_minecraft_username)
      )
      returning id, user_id into v_account_id, v_account_user_id;

      exit;
    exception when unique_violation then
      -- Another request created the same username; loop and lock that row.
      null;
    end;
  end loop;

  if v_account_user_id <> p_user_id then
    return jsonb_build_object(
      'result', 'account_owned',
      'error_message', 'Minecraft username belongs to another account'
    );
  end if;

  -- The account row lock serializes membership extension for this account.
  select * into v_membership
  from public.memberships
  where minecraft_account_id = v_account_id
    and status = 'active'
  order by expires_at desc
  limit 1
  for update;

  v_has_membership := found;
  v_start := case
    when v_has_membership and v_membership.expires_at > v_now
      then v_membership.expires_at
    else v_now
  end;
  v_expiry := v_start + make_interval(days => v_code.duration_days);

  -- All writes below are in this same transaction. Any SQL error rolls them back.
  insert into public.redemptions (code_id, user_id, minecraft_username)
  values (v_code.id, p_user_id, trim(p_minecraft_username));

  update public.redeem_codes
  set uses = uses + 1
  where id = v_code.id;

  if v_has_membership then
    update public.memberships
    set expires_at = v_expiry,
        status = 'active',
        reminder_sent = null
    where id = v_membership.id;
  else
    insert into public.memberships (
      user_id, minecraft_account_id, status, starts_at, expires_at
    )
    values (
      p_user_id, v_account_id, 'active', v_now, v_expiry
    );
  end if;

  -- Upsert Discord mapping by user_id (the existing Worker uses this key).
  insert into public.discord_accounts (user_id, discord_id)
  values (p_user_id, trim(p_discord_id))
  on conflict (user_id) do update
    set discord_id = excluded.discord_id;

  return jsonb_build_object(
    'result', 'redeemed',
    'expires_at', v_expiry,
    'duration_days', v_code.duration_days,
    'error_message', null
  );
end;
$$;

revoke all on function public.redeem_gift_code(text, text, uuid, text) from public;
revoke all on function public.redeem_gift_code(text, text, uuid, text) from anon;
revoke all on function public.redeem_gift_code(text, text, uuid, text) from authenticated;
grant execute on function public.redeem_gift_code(text, text, uuid, text) to service_role;
