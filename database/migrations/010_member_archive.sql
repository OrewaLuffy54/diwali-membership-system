-- Diwali Network: archive support for safe member deletion.
-- Additive only. Existing account, membership, payment and audit rows are preserved.
ALTER TABLE public.minecraft_accounts
  ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;

CREATE INDEX IF NOT EXISTS minecraft_accounts_active_archive_idx
  ON public.minecraft_accounts (archived_at)
  WHERE archived_at IS NULL;
