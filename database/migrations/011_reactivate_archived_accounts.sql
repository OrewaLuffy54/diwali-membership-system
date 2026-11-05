-- Migration 011: automatically unarchive a Minecraft account when it is reactivated.
-- Requires migrations 008 (edition-aware RPCs) and 010 (minecraft_accounts.archived_at).
-- Safe to apply once; CREATE OR REPLACE updates the existing RPCs without deleting data.
-- Payment history, redemptions, memberships, and audit history are preserved.

-- Additive Java/Bedrock metadata. Existing records default to Java and are preserved.
alter table public.minecraft_accounts add column if not exists edition text not null default 'java' check (edition in ('java','bedrock'));
alter table public.payment_submissions add column if not exists edition text not null default 'java' check (edition in ('java','bedrock'));
alter table public.redemptions add column if not exists edition text not null default 'java' check (edition in ('java','bedrock'));

-- Keep the existing globally unique username model; edition selects whitelist routing.
create or replace function public.approve_payment_submission(p_submission_id uuid)
returns table(result text, expires_at timestamptz, error_message text)
language plpgsql security definer set search_path=public as $$
declare
 v_payment payment_submissions%rowtype; v_coupon coupon_codes%rowtype; v_account_id uuid;
 v_membership memberships%rowtype; v_has_membership boolean:=false; v_expiry timestamptz; v_usage_id uuid;
begin
 select * into v_payment from payment_submissions where id=p_submission_id for update;
 if not found then return query select 'not_found'::text,null::timestamptz,'Submission not found'::text; return; end if;
 if v_payment.status<>'pending' then return query select 'already_processed'::text,null::timestamptz,'Payment has already been processed'::text; return; end if;
 if v_payment.coupon_code is not null then
  select * into v_coupon from coupon_codes where code_normalized=upper(v_payment.coupon_code) for update;
  if not found or not v_coupon.active or (v_coupon.expires_at is not null and v_coupon.expires_at<=now()) or (v_coupon.max_uses is not null and v_coupon.uses>=v_coupon.max_uses) then
   return query select 'coupon_invalid'::text,null::timestamptz,'Coupon is disabled, expired, exhausted, or no longer exists'::text; return;
  end if;
 end if;
 loop
  select id into v_account_id from minecraft_accounts where lower(minecraft_username)=lower(v_payment.minecraft_username) for update;
  exit when found;
  insert into minecraft_accounts(user_id,discord_id,minecraft_username,edition) values(v_payment.user_id,v_payment.discord_id,v_payment.minecraft_username,coalesce(v_payment.edition,'java'))
  on conflict(minecraft_username) do nothing returning id into v_account_id;
  exit when found;
 end loop;
 update minecraft_accounts set user_id=v_payment.user_id,discord_id=v_payment.discord_id,edition=coalesce(v_payment.edition,'java'),archived_at=null where id=v_account_id;
 select * into v_membership from memberships where minecraft_account_id=v_account_id and status='active' order by expires_at desc limit 1 for update;
 v_has_membership:=found;
 v_expiry:=(case when v_has_membership and v_membership.expires_at>now() then v_membership.expires_at else now() end)+make_interval(days=>v_payment.duration_days);
 if v_has_membership then update memberships set user_id=v_payment.user_id,expires_at=v_expiry,status='active',reminder_sent=null where id=v_membership.id;
 else insert into memberships(user_id,minecraft_account_id,status,starts_at,expires_at) values(v_payment.user_id,v_account_id,'active',now(),v_expiry); end if;
 insert into discord_accounts(user_id,discord_id) values(v_payment.user_id,v_payment.discord_id) on conflict(user_id) do update set discord_id=excluded.discord_id;
 if v_payment.coupon_code is not null then
  insert into coupon_payment_usages(coupon_id,payment_submission_id) values(v_coupon.id,v_payment.id) on conflict(payment_submission_id) do nothing returning id into v_usage_id;
  if not found then raise exception 'Coupon usage already recorded for this payment'; end if;
  update coupon_codes set uses=uses+1,updated_at=now() where id=v_coupon.id;
 end if;
 update payment_submissions set status='approved',reviewed_at=now() where id=v_payment.id;
 return query select 'approved'::text,v_expiry,null::text;
end; $$;

-- Edition-aware gift redemption overload; retain the previous 4-argument RPC for compatibility.
create or replace function public.redeem_gift_code(p_code text,p_minecraft_username text,p_user_id uuid,p_discord_id text,p_edition text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_code redeem_codes%rowtype; v_account_id uuid; v_membership memberships%rowtype; v_has_membership boolean:=false;
 v_now timestamptz:=now(); v_start timestamptz; v_expiry timestamptz; v_edition text:=lower(coalesce(p_edition,'java'));
begin
 if p_user_id is null or coalesce(trim(p_discord_id),'')='' or trim(coalesce(p_minecraft_username,'')) !~ '^[A-Za-z0-9_]{3,16}$' or trim(coalesce(p_code,''))='' or v_edition not in('java','bedrock') then
  return jsonb_build_object('result','invalid_input','error_message','Enter a valid gift code, Minecraft username, and edition'); end if;
 select * into v_code from redeem_codes where code=upper(trim(p_code)) and code_type='gift' for update;
 if not found or not v_code.active then return jsonb_build_object('result','invalid_code','error_message','Gift code is invalid or disabled'); end if;
 if v_code.expires_at is not null and v_code.expires_at<=v_now then return jsonb_build_object('result','expired','error_message','Gift code has expired'); end if;
 if v_code.uses>=v_code.max_uses then return jsonb_build_object('result','exhausted','error_message','Gift code usage limit reached'); end if;
 if exists(select 1 from redemptions where code_id=v_code.id and user_id=p_user_id) then return jsonb_build_object('result','already_redeemed','error_message','This account already redeemed this gift code'); end if;
 loop
  select id into v_account_id from minecraft_accounts where lower(minecraft_username)=lower(trim(p_minecraft_username)) for update;
  exit when found;
  begin insert into minecraft_accounts(user_id,discord_id,minecraft_username,edition) values(p_user_id,trim(p_discord_id),trim(p_minecraft_username),v_edition) returning id into v_account_id; exit;
  exception when unique_violation then null; end;
 end loop;
 update minecraft_accounts set user_id=p_user_id,discord_id=trim(p_discord_id),edition=v_edition,archived_at=null where id=v_account_id;
 select * into v_membership from memberships where minecraft_account_id=v_account_id and status='active' order by expires_at desc limit 1 for update;
 v_has_membership:=found; v_start:=case when v_has_membership and v_membership.expires_at>v_now then v_membership.expires_at else v_now end;
 v_expiry:=v_start+make_interval(days=>v_code.duration_days);
 insert into redemptions(code_id,user_id,minecraft_username,edition) values(v_code.id,p_user_id,trim(p_minecraft_username),v_edition);
 update redeem_codes set uses=uses+1 where id=v_code.id;
 if v_has_membership then update memberships set user_id=p_user_id,expires_at=v_expiry,status='active',reminder_sent=null where id=v_membership.id;
 else insert into memberships(user_id,minecraft_account_id,status,starts_at,expires_at) values(p_user_id,v_account_id,'active',v_now,v_expiry); end if;
 insert into discord_accounts(user_id,discord_id) values(p_user_id,trim(p_discord_id)) on conflict(user_id) do update set discord_id=excluded.discord_id;
 return jsonb_build_object('result','redeemed','expires_at',v_expiry,'duration_days',v_code.duration_days,'edition',v_edition,'error_message',null);
end; $$;
revoke all on function public.redeem_gift_code(text,text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.redeem_gift_code(text,text,uuid,text,text) to service_role;

notify pgrst, 'reload schema';


-- Restore the Bedrock account shown in the admin screenshot only if it currently has
-- an unexpired active membership. This is a targeted, reversible unarchive; no rows are deleted.
update public.minecraft_accounts as account
set archived_at = null
where lower(account.minecraft_username) = lower('ArshGaming3395')
  and account.archived_at is not null
  and exists (
    select 1
    from public.memberships as membership
    where membership.minecraft_account_id = account.id
      and membership.status = 'active'
      and membership.expires_at > now()
  );

-- Verify the account visibility and membership state.
select account.minecraft_username, account.edition, account.archived_at,
       membership.status, membership.expires_at
from public.minecraft_accounts as account
left join public.memberships as membership
  on membership.minecraft_account_id = account.id
where lower(account.minecraft_username) = lower('ArshGaming3395')
order by membership.expires_at desc;
