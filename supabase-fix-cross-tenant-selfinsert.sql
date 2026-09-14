-- Fix cross-tenant privilege escalation via rm_users self-insert.
--
-- Found 2026-09-14 during a portfolio-wide check for the same bug class
-- as Derasar Boli's dr_profiles issue (see that repo's
-- supabase-fix-pending-profile-privilege-escalation.sql). Every table's
-- RLS here ultimately trusts rm_current_org_id():
--
--   select org_id from rm_users where auth_uid = auth.uid();
--
-- ...and the self-insert policy on rm_users ("Allow insert own user
-- row") only checked `auth_uid = auth.uid()` — org_id and role were
-- fully client-controlled. Any authenticated user could self-insert
-- {org_id: <any existing org>, role: 'admin'} and get immediate full
-- access to that org's items/completions/alert rules, no invite or
-- approval needed.
--
-- Unlike Derasar Boli, rm_users.is_active defaults to true for every
-- row and isn't used as an approval gate here, so adding an is_active
-- check would NOT have closed this. Instead: self-insert is now only
-- allowed as the FIRST member of a brand-new org (a fresh org_id has
-- zero existing rm_users rows) - the legitimate founder-signup case.
-- Claiming an org_id that already has a member must go through the
-- existing "Admin can add members to own org" (invite, requires
-- already being that org's admin) or "Claim own invited row"
-- (email-matched) policies, both already correctly scoped and
-- untouched by this change.
--
-- Verified safe before applying directly to the live DB: all 5
-- existing orgs already have >=1 member, so this was a no-op for every
-- current account.
--
-- NOTE on how this was written: a first version of this policy used
-- `where u2.org_id = org_id` (org_id on the right left unqualified,
-- relying on it correlating to the row being inserted). Postgres
-- instead resolved it to the subquery's own u2.org_id (closest scope),
-- making the condition always true and briefly blocking ALL new
-- signups, not just cross-tenant ones - caught immediately by
-- re-reading the applied policy back from pg_policies, fixed by
-- qualifying the outer reference as `rm_users.org_id` (the table's own
-- name IS a valid way to reference the row being checked in a Postgres
-- RLS policy expression), and verified against real data before
-- reapplying. The version below is the corrected one.

drop policy if exists "Allow insert own user row" on rm_users;

create policy "Allow insert own user row" on rm_users
  for insert to authenticated
  with check (
    auth_uid = auth.uid()
    and not exists (select 1 from rm_users u2 where u2.org_id = rm_users.org_id)
  );
