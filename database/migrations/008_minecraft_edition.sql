-- Diwali Network: store Minecraft edition for membership targets and payment history.
-- Additive migration; existing rows remain and default to Java.
ALTER TABLE public.minecraft_accounts
  ADD COLUMN IF NOT EXISTS edition text NOT NULL DEFAULT 'java';

ALTER TABLE public.payment_submissions
  ADD COLUMN IF NOT EXISTS edition text NOT NULL DEFAULT 'java';

ALTER TABLE public.minecraft_accounts
  DROP CONSTRAINT IF EXISTS minecraft_accounts_edition_check;
ALTER TABLE public.minecraft_accounts
  ADD CONSTRAINT minecraft_accounts_edition_check CHECK (edition IN ('java','bedrock'));

ALTER TABLE public.payment_submissions
  DROP CONSTRAINT IF EXISTS payment_submissions_edition_check;
ALTER TABLE public.payment_submissions
  ADD CONSTRAINT payment_submissions_edition_check CHECK (edition IN ('java','bedrock'));
