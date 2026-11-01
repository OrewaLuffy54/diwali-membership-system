# Diwali Network Membership System

Discord OAuth membership portal for the Diwali Network Minecraft server. Frontend: React + Vite. API: Cloudflare Worker. Database/Auth: Supabase. Minecraft whitelist sync: the included Paper plugin.

## What's included

- Discord OAuth sign-in through Supabase Auth.
- Subscription plans (30/90/180/365 days) with admin-editable prices/durations in the database.
- Manual UPI payment submission and admin approval/rejection.
- Free gift-code generation and redemption. Gift redemption is restricted to `code_type = gift`; promotional discounts are stored separately in `coupon_codes`.
- Discord-ID-based admin login and per-permission access checks on the Worker.
- Role presets: Admin, Moderator, Support, Payment Manager, Membership Manager, Coupon Manager, and Custom.
- Owner dashboard to add admins by Discord User ID, edit individual permissions, disable/remove admins, review members/payments, create coupons/gift codes, and inspect audit logs.
- Membership expiry cron and optional Discord DM reminders.

## Preserve your current setup

1. Keep your existing `frontend/.env` file. It is intentionally not included in this ZIP.
2. Do not reset Supabase or rerun the original schema as a reset. The existing `database/schema.sql` is retained as project reference.
3. Run the additive migrations in order: `database/migrations/002_admin_permissions.sql`, `database/migrations/003_add_second_owner.sql`, `database/migrations/004_coupon_lifecycle.sql`, then `database/migrations/005_coupon_concurrency_fixes.sql` in Supabase SQL Editor. Before running 004, use its documented read-only coupon preflight query. Migration 004 retains existing records, adds unlimited coupon support and usage records, and installs the transactional approval RPC; migration 005 closes coupon-reference races and serializes first-time account creation. Neither drops or truncates membership, payment, coupon, gift-code, or admin data.
4. Keep your existing Supabase Discord OAuth provider and redirect URLs.

## Cloudflare Worker secrets

From the `worker` folder, configure the secrets (never put these in frontend `.env` or commit them):

```bash
npx wrangler secret put SUPABASE_URL
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
npx wrangler secret put PLUGIN_SECRET
npx wrangler secret put DISCORD_BOT_TOKEN
```

`DISCORD_BOT_TOKEN` is optional for core membership activation but required for Discord DMs. `SUPABASE_ANON_KEY` is optional; if supplied as a Worker secret it is used for validating user JWTs, otherwise the Worker uses the service key as the Auth API key while validating the supplied bearer token. `ADMIN_DISCORD_ID` is retained for backward compatibility. `ADMIN_DISCORD_IDS` contains both protected Owner IDs: `1013832671014699130` and `868853678868680734`. Keep both values in `worker/wrangler.toml` and deploy after applying migration 003.

Deploy the Worker after the migration:

```bash
npm install
npx wrangler deploy
```

After the deploy, sign in as an Owner or an admin with `manage_coupons`, open **Coupon management**, and create the `TEST10` coupon (10%, a future expiry, and a small usage limit) for a live smoke test. Do not create the test coupon directly from the browser or expose any Worker secret.

## Frontend setup

Create `frontend/.env` from `.env.example` and set:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_KEY
VITE_API_BASE=https://YOUR-WORKER.workers.dev
```

Then:

```bash
npm install
npm run dev
```

For a production frontend, deploy the Vite `dist` folder to Cloudflare Pages and set the same three `VITE_` variables in Pages build settings.

## Admin permissions

Sign in with either Owner Discord account: `1013832671014699130` or `868853678868680734`. The Worker grants both IDs Owner access from server-side configuration. Neither Owner can be added, edited, disabled, or removed through the regular admin manager. Open the Admin Dashboard, enter another user's numeric Discord User ID (not username), choose a preset, and customize checkboxes before adding. Existing admins can be edited, disabled, or removed. `manage_admins` is Owner-only and is never grantable through the custom permission editor.

Available permission keys: `view_members`, `view_payments`, `approve_payments`, `reject_payments`, `manage_memberships`, `create_gift_codes`, `manage_coupons`, `manage_plans`, `view_audit_logs`. Admin identity and permissions are rechecked server-side for every protected API route; hiding a UI panel is not the security boundary.

## Important security notes

- Never expose `SUPABASE_SERVICE_ROLE_KEY`, `PLUGIN_SECRET`, or `DISCORD_BOT_TOKEN` in frontend variables or public repositories.
- A Discord OAuth client secret was previously pasted into a chat. Regenerate it in Discord Developer Portal and update the Supabase Discord provider before production use.
- Payment approval remains a manual verification workflow. Verify UTR against your payment account; do not approve based only on a screenshot.
- Back up the Supabase database before production migrations/deployments.

## Validation

Run `npm run build` in `frontend`, then `npx tsc --noEmit` and `npm test` in `worker` after installing dependencies. The worker test uses a `TEST10` fixture and verifies ₹50 → ₹45, expired/disabled rejection, limits, quote-only usage behavior, and the non-negative payable guard. For the production smoke test, create `TEST10` from the protected admin UI, quote it against the ₹50 monthly plan, submit a distinct test UTR, approve it once, then confirm the coupon’s successful-use count changes from 0 to 1. Retrying approval must return “already processed” without another increment.


## Code style and maintainability

The Worker uses descriptive helper names for owner checks, Discord identity lookup, permission checks, database access, membership activation, and audit logging. Keep secrets and authorization decisions server-side. Prefer small named helpers and clear error messages when extending the API; do not put credentials or private tokens in source files.
