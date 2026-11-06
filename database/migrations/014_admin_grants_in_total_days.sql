-- Migration 014: include admin-granted extensions in Total granted days.
-- Payment and gift entitlements remain sourced from their existing immutable ledgers.
-- Admin extensions are recorded exactly once by apply_membership_days.

CREATE TABLE IF NOT EXISTS public.membership_admin_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  minecraft_account_id uuid NOT NULL REFERENCES public.minecraft_accounts(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL,
  duration_days integer NOT NULL CHECK (duration_days BETWEEN 1 AND 3650),
  granted_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL DEFAULT 'admin_extension' CHECK (source = 'admin_extension')
);

CREATE INDEX IF NOT EXISTS membership_admin_grants_account_idx
  ON public.membership_admin_grants (minecraft_account_id);

ALTER TABLE public.membership_admin_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.membership_admin_grants FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.membership_admin_grants TO service_role;

-- Rebuild the displayed lifetime total from payments, gift redemptions,
-- and admin extensions. Expiration never subtracts historical granted days.
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

  UNION ALL

  SELECT g.minecraft_account_id, g.duration_days
  FROM public.membership_admin_grants AS g
)
SELECT ma.id AS minecraft_account_id,
       coalesce(sum(e.duration_days), 0)::integer AS total_days,
       count(e.duration_days)::integer AS entitlement_count
FROM public.minecraft_accounts AS ma
LEFT JOIN entitlement_events AS e ON e.minecraft_account_id = ma.id
GROUP BY ma.id;

GRANT SELECT ON public.membership_entitlement_totals TO service_role;

-- Replace the V2 grant function. It keeps only valid remaining time and records
-- every successful admin extension in the lifetime Total granted ledger.
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
  v_base timestamptz;
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
    IF v_membership.status = 'active' AND v_membership.expires_at > v_now THEN
      v_base := v_membership.expires_at;
    ELSE
      v_base := v_now;
    END IF;

    v_expiry := v_base + make_interval(days => p_duration_days);
    UPDATE public.memberships
    SET user_id = p_user_id,
        starts_at = CASE
          WHEN v_membership.status IN ('expired', 'cancelled')
               OR v_membership.expires_at <= v_now THEN v_now
          ELSE starts_at
        END,
        expires_at = v_expiry,
        status = 'active',
        reminder_sent = NULL
    WHERE id = v_membership.id;
  ELSE
    v_expiry := v_now + make_interval(days => p_duration_days);
    INSERT INTO public.memberships(user_id, minecraft_account_id, status, starts_at, expires_at)
    VALUES (p_user_id, p_minecraft_account_id, 'active', v_now, v_expiry);
  END IF;

  INSERT INTO public.membership_admin_grants(
    minecraft_account_id, user_id, duration_days, granted_at
  ) VALUES (
    p_minecraft_account_id, p_user_id, p_duration_days, v_now
  );

  RETURN v_expiry;
END;
$function$;

REVOKE ALL ON FUNCTION public.apply_membership_days(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_membership_days(uuid, uuid, integer) TO service_role;
