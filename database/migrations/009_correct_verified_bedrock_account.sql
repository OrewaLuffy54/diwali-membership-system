-- Diwali Network: correct the verified existing Bedrock account edition.
-- Run only after migration 008 has added minecraft_accounts.edition.
-- This changes one account's edition metadata; it does not alter memberships or payment history.
UPDATE public.minecraft_accounts
SET edition = 'bedrock'
WHERE lower(minecraft_username) = lower('ArshGaming3395');

-- Verify the result (expected edition: bedrock).
SELECT minecraft_username, edition
FROM public.minecraft_accounts
WHERE lower(minecraft_username) = lower('ArshGaming3395');
