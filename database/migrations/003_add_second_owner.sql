-- Diwali Network: add a second protected Owner account.
-- Safe additive migration; existing membership and payment data is untouched.
alter table if exists admin_roles drop constraint if exists admin_roles_role_check;
alter table if exists admin_roles
  add constraint admin_roles_role_check
  check (role in ('owner','admin','moderator','support','payment_manager','membership_manager','coupon_manager','custom'));

-- Both configured Owner Discord IDs receive full access.
insert into admin_roles(discord_id, role, permissions, active, granted_by)
values
  ('1013832671014699130', 'owner', '["*"]'::jsonb, true, 'system'),
  ('868853678868680734', 'owner', '["*"]'::jsonb, true, 'system')
on conflict (discord_id) do update
set role = 'owner', permissions = '["*"]'::jsonb, active = true, updated_at = now();
