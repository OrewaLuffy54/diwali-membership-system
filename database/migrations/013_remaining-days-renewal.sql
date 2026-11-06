-- Membership V2: only a currently valid active membership carries remaining time.
-- Expired/cancelled rows contribute zero days, even if a stale expiry timestamp is in the future.
-- Gift redemption and payment approval already call apply_membership_days from migration 012.

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

  -- Serialize all grants for the same Minecraft account (gift, payment, admin).
  PERFORM 1 FROM public.minecraft_accounts
  WHERE id = p_minecraft_account_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Minecraft account not found'; END IF;

  SELECT * INTO v_membership
  FROM public.memberships
  WHERE minecraft_account_id = p_minecraft_account_id
  FOR UPDATE;

  IF FOUND THEN
    -- Carry forward only genuinely remaining time on an active membership.
    -- Expired/cancelled status always resets the base to now.
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

  RETURN v_expiry;
END;
$function$;

REVOKE ALL ON FUNCTION public.apply_membership_days(uuid, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_membership_days(uuid, uuid, integer) TO service_role;
