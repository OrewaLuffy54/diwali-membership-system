-- Membership consolidation and safe extension migration.
-- Keeps a complete JSON snapshot of every pre-migration membership row before deduplication.

CREATE TABLE IF NOT EXISTS public.membership_consolidation_archive (
  membership_id uuid PRIMARY KEY,
  minecraft_account_id uuid NOT NULL,
  row_data jsonb NOT NULL,
  archived_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.membership_consolidation_archive ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.membership_consolidation_archive TO service_role;

-- Snapshot every current row once. This is intentionally retained as an audit/rollback source.
INSERT INTO public.membership_consolidation_archive(membership_id, minecraft_account_id, row_data)
SELECT m.id, m.minecraft_account_id, to_jsonb(m)
FROM public.memberships AS m
ON CONFLICT (membership_id) DO NOTHING;

-- Rebuild the entitlement timeline from the immutable source records.
-- Each approved payment and each redeemed gift contributes its duration exactly once.
-- Events are applied in timestamp order; a new event starts after the later of its
-- own timestamp or the previous entitlement expiry.
CREATE OR REPLACE VIEW public.membership_entitlement_totals AS
WITH entitlement_events AS (
  SELECT ma.id AS minecraft_account_id, p.duration_days
  FROM public.minecraft_accounts AS ma
  JOIN public.payment_submissions AS p
    ON lower(p.minecraft_username) = lower(ma.minecraft_username)
  WHERE p.status = 'approved'
  UNION ALL
  SELECT ma.id AS minecraft_account_id, rc.duration_days
  FROM public.minecraft_accounts AS ma
  JOIN public.redemptions AS r
    ON lower(r.minecraft_username) = lower(ma.minecraft_username)
  JOIN public.redeem_codes AS rc ON rc.id = r.code_id
)
SELECT ma.id AS minecraft_account_id,
       coalesce(sum(e.duration_days), 0)::integer AS total_days,
       count(e.duration_days)::integer AS entitlement_count
FROM public.minecraft_accounts AS ma
LEFT JOIN entitlement_events AS e ON e.minecraft_account_id = ma.id
GROUP BY ma.id;

GRANT SELECT ON public.membership_entitlement_totals TO service_role;

-- Avoid violating the pre-existing one-active-row partial unique index while
-- the canonical row is being selected. Only accounts with duplicates are touched.
UPDATE public.memberships AS m
SET status = 'expired'
WHERE m.status = 'active'
  AND EXISTS (
    SELECT 1 FROM public.memberships AS d
    WHERE d.minecraft_account_id = m.minecraft_account_id
      AND d.id <> m.id
  );

-- Calculate each account's ledger-derived expiry. The maximum existing expiry is
-- also retained, so manual/admin extensions are never shortened.
WITH RECURSIVE entitlement_events AS (
  SELECT ma.id AS minecraft_account_id,
         coalesce(p.reviewed_at, p.created_at) AS event_at,
         p.duration_days,
         ('payment:' || p.id::text) AS event_key
  FROM public.minecraft_accounts AS ma
  JOIN public.payment_submissions AS p
    ON lower(p.minecraft_username) = lower(ma.minecraft_username)
  WHERE p.status = 'approved'
  UNION ALL
  SELECT ma.id AS minecraft_account_id,
         r.redeemed_at AS event_at,
         rc.duration_days,
         ('redemption:' || r.id::text) AS event_key
  FROM public.minecraft_accounts AS ma
  JOIN public.redemptions AS r
    ON lower(r.minecraft_username) = lower(ma.minecraft_username)
  JOIN public.redeem_codes AS rc ON rc.id = r.code_id
), ordered_events AS (
  SELECT minecraft_account_id, event_at, duration_days,
         row_number() OVER (
           PARTITION BY minecraft_account_id
           ORDER BY event_at, event_key
         ) AS rn
  FROM entitlement_events
), ledger AS (
  SELECT minecraft_account_id, rn, event_at,
         event_at + make_interval(days => duration_days) AS calculated_expiry
  FROM ordered_events WHERE rn = 1
  UNION ALL
  SELECT e.minecraft_account_id, e.rn, e.event_at,
         greatest(l.calculated_expiry, e.event_at)
           + make_interval(days => e.duration_days) AS calculated_expiry
  FROM ledger AS l
  JOIN ordered_events AS e
    ON e.minecraft_account_id = l.minecraft_account_id
   AND e.rn = l.rn + 1
), ledger_summary AS (
  SELECT minecraft_account_id,
         min(event_at) AS first_entitlement_at,
         max(calculated_expiry) AS ledger_expiry
  FROM ledger
  GROUP BY minecraft_account_id
), ranked AS (
  SELECT m.id, m.minecraft_account_id,
         row_number() OVER (
           PARTITION BY m.minecraft_account_id
           ORDER BY (m.status <> 'cancelled') DESC, m.expires_at DESC, (m.status = 'active') DESC, m.created_at ASC, m.id ASC
         ) AS rn,
         min(m.starts_at) OVER (PARTITION BY m.minecraft_account_id) AS earliest_start,
         max(m.expires_at) OVER (PARTITION BY m.minecraft_account_id) AS latest_all_expiry,
         max(m.expires_at) FILTER (WHERE m.status <> 'cancelled')
           OVER (PARTITION BY m.minecraft_account_id) AS latest_entitled_expiry,
         bool_or(m.status <> 'cancelled') OVER (PARTITION BY m.minecraft_account_id) AS has_non_cancelled
  FROM public.memberships AS m
), canonical AS (
  SELECT r.id, r.minecraft_account_id, r.earliest_start,
         CASE WHEN r.has_non_cancelled
              THEN greatest(r.latest_entitled_expiry, coalesce(ls.ledger_expiry, r.latest_entitled_expiry))
              ELSE r.latest_all_expiry END AS final_expiry,
         ls.first_entitlement_at,
         r.has_non_cancelled
  FROM ranked AS r
  LEFT JOIN ledger_summary AS ls ON ls.minecraft_account_id = r.minecraft_account_id
  WHERE r.rn = 1
)
UPDATE public.memberships AS m
SET starts_at = least(c.earliest_start, coalesce(c.first_entitlement_at, c.earliest_start)),
    expires_at = c.final_expiry,
    status = CASE WHEN NOT c.has_non_cancelled THEN 'cancelled'
                  WHEN c.final_expiry > now() THEN 'active' ELSE 'expired' END,
    reminder_sent = CASE WHEN c.has_non_cancelled AND c.final_expiry > now() THEN NULL ELSE m.reminder_sent END
FROM canonical AS c
WHERE m.id = c.id;

WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY minecraft_account_id
           ORDER BY (status <> 'cancelled') DESC, expires_at DESC, (status = 'active') DESC, created_at ASC, id ASC
         ) AS rn
  FROM public.memberships
)
DELETE FROM public.memberships AS m
USING ranked AS r
WHERE m.id = r.id AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS memberships_one_row_per_account_uidx
  ON public.memberships(minecraft_account_id);

-- All membership extensions (gift, payment, future admin automation) go through this
-- account-locked function, and include expired rows rather than only status='active'.
CREATE OR REPLACE FUNCTION public.apply_membership_days(
  p_minecraft_account_id uuid,
  p_user_id uuid,
  p_duration_days integer
) RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_membership public.memberships%rowtype;
  v_now timestamptz := now();
  v_expiry timestamptz;
BEGIN
  IF p_minecraft_account_id IS NULL OR p_user_id IS NULL
     OR p_duration_days IS NULL OR p_duration_days < 1 OR p_duration_days > 3650 THEN
    RAISE EXCEPTION 'Invalid membership extension arguments';
  END IF;

  PERFORM 1 FROM public.minecraft_accounts
  WHERE id = p_minecraft_account_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Minecraft account not found'; END IF;

  SELECT * INTO v_membership
  FROM public.memberships
  WHERE minecraft_account_id = p_minecraft_account_id
  FOR UPDATE;

  IF FOUND THEN
    v_expiry := greatest(
                  CASE WHEN v_membership.status = 'cancelled' THEN v_now ELSE v_membership.expires_at END,
                  v_now
                ) + make_interval(days => p_duration_days);
    UPDATE public.memberships
    SET user_id = p_user_id,
        starts_at = CASE WHEN status = 'cancelled' THEN v_now ELSE starts_at END,
        expires_at = v_expiry,
        status = 'active',
        reminder_sent = NULL
    WHERE id = v_membership.id;
  ELSE
    v_expiry := v_now + make_interval(days => p_duration_days);
    INSERT INTO public.memberships(user_id, minecraft_account_id, status, starts_at, expires_at)
    VALUES (p_user_id, p_minecraft_account_id, 'active', v_now, v_expiry);
  END IF;
  RETURN v_expiry;
END;
$function$;

REVOKE ALL ON FUNCTION public.apply_membership_days(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_membership_days(uuid, uuid, integer) TO service_role;



-- Payment approval now extends the single canonical membership row.
CREATE OR REPLACE FUNCTION public.approve_payment_submission(p_submission_id uuid)
 RETURNS TABLE(result text, expires_at timestamp with time zone, error_message text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
 v_expiry := public.apply_membership_days(v_account_id, v_payment.user_id, v_payment.duration_days);
 insert into discord_accounts(user_id,discord_id) values(v_payment.user_id,v_payment.discord_id) on conflict(user_id) do update set discord_id=excluded.discord_id;
 if v_payment.coupon_code is not null then
  insert into coupon_payment_usages(coupon_id,payment_submission_id) values(v_coupon.id,v_payment.id) on conflict(payment_submission_id) do nothing returning id into v_usage_id;
  if not found then raise exception 'Coupon usage already recorded for this payment'; end if;
  update coupon_codes set uses=uses+1,updated_at=now() where id=v_coupon.id;
 end if;
 update payment_submissions set status='approved',reviewed_at=now() where id=v_payment.id;
 return query select 'approved'::text,v_expiry,null::text;
end; $function$;


-- Edition-aware gift redemption now extends the same canonical membership row.
CREATE OR REPLACE FUNCTION public.redeem_gift_code(p_code text, p_minecraft_username text, p_user_id uuid, p_discord_id text, p_edition text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
 v_expiry := public.apply_membership_days(v_account_id, p_user_id, v_code.duration_days);
 insert into redemptions(code_id,user_id,minecraft_username,edition) values(v_code.id,p_user_id,trim(p_minecraft_username),v_edition);
 update redeem_codes set uses=uses+1 where id=v_code.id;
 -- Membership was atomically consolidated and extended above.
 insert into discord_accounts(user_id,discord_id) values(p_user_id,trim(p_discord_id)) on conflict(user_id) do update set discord_id=excluded.discord_id;
 return jsonb_build_object('result','redeemed','expires_at',v_expiry,'duration_days',v_code.duration_days,'edition',v_edition,'error_message',null);
end; $function$;


-- Legacy callers remain supported but cannot bypass the consolidated logic.
CREATE OR REPLACE FUNCTION public.redeem_gift_code(p_code text, p_minecraft_username text, p_user_id uuid, p_discord_id text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.redeem_gift_code(p_code, p_minecraft_username, p_user_id, p_discord_id, 'java');
$function$;
