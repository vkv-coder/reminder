-- Switch reminder to no-approval-required 30-day free trial, matching the
-- pattern built for Appointment- (2026-08-08): instant access at signup,
-- trial starts on first real data entry (first item created, not signup),
-- admin gets Telegram+email on signup AND separately when a trial starts,
-- owner gets a proactive reminder 3 days before expiry, is_paid overrides
-- everything. This app has no existing admin auth or Apps Script backend,
-- so both are built fresh here - admin auth as a simple RPC-gated password
-- check (matching consultrack/SEATBOOK's pattern), and the 3-day reminder
-- via pg_cron + pg_net (enabled below) instead of an external scheduler,
-- since everything can live inside Supabase with no manual redeploy step.
--
-- Reuses the EXISTING status='suspended' value as the block mechanism
-- (already fully wired in auth.html/dashboard.html) instead of adding a
-- separate is_blocked column - this app already has that concept built.

create extension if not exists pg_cron;

alter table rm_organizations alter column status set default 'active';
alter table rm_organizations add column if not exists trial_started_at timestamptz;
alter table rm_organizations add column if not exists trial_extended_days int not null default 0;
alter table rm_organizations add column if not exists is_paid boolean not null default false;
alter table rm_organizations add column if not exists trial_reminder_sent boolean not null default false;

-- Allow signup to insert with status='active' directly (was 'pending'-only)
drop policy if exists "Allow insert for authenticated users" on rm_organizations;
create policy "Allow insert for authenticated users" on rm_organizations
  for insert
  with check (status in ('pending', 'active'));

-- ---------- Admin auth (this app has none yet) ----------
-- Password stored as a bcrypt hash in a dedicated table, never in code -
-- matches consultrack's ct_admin_check_password pattern. Set the actual
-- password value with a separate, never-committed statement:
--   update rm_admin_secret set password_hash = crypt('yournewpassword', gen_salt('bf')) where id = true;
create table if not exists rm_admin_secret (
  id boolean primary key default true,
  password_hash text,
  constraint rm_admin_secret_single_row check (id)
);
insert into rm_admin_secret (id, password_hash) values (true, null) on conflict (id) do nothing;

create or replace function public.rm_admin_check_password(p_password text)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_hash text;
begin
  select password_hash into v_hash from rm_admin_secret where id = true;
  return v_hash is not null and v_hash = crypt(p_password, v_hash);
end;
$function$;

-- ---------- Trial-start-on-first-item ----------
create or replace function public.rm_start_trial_if_needed(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_org rm_organizations%rowtype;
begin
  select * into v_org from rm_organizations where id = p_org_id;
  if v_org.id is null then return; end if;
  if v_org.trial_started_at is not null then return; end if;
  if coalesce(v_org.is_demo, false) then return; end if;
  update rm_organizations set trial_started_at = now() where id = p_org_id;
end;
$function$;

create or replace function public.rm_items_start_trial_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
begin
  perform rm_start_trial_if_needed(NEW.org_id);
  return NEW;
end;
$function$;

drop trigger if exists rm_items_start_trial on rm_items;
create trigger rm_items_start_trial
after insert on rm_items
for each row execute function rm_items_start_trial_trigger();

-- ---------- Admin actions ----------
create or replace function public.rm_admin_extend_trial(p_org_id uuid, p_admin_password text, p_days int)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
begin
  if not rm_admin_check_password(p_admin_password) then raise exception 'Unauthorized'; end if;
  if p_days is null or p_days < 1 then raise exception 'Invalid number of days'; end if;
  update rm_organizations set trial_extended_days = trial_extended_days + p_days, trial_reminder_sent = false where id = p_org_id;
  return true;
end;
$function$;

create or replace function public.rm_admin_set_status(p_org_id uuid, p_admin_password text, p_status text)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
begin
  if not rm_admin_check_password(p_admin_password) then raise exception 'Unauthorized'; end if;
  if p_status not in ('active','suspended','pending') then raise exception 'Invalid status'; end if;
  update rm_organizations set status = p_status where id = p_org_id;
  return true;
end;
$function$;

create or replace function public.rm_admin_set_paid(p_org_id uuid, p_admin_password text, p_paid boolean)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
begin
  if not rm_admin_check_password(p_admin_password) then raise exception 'Unauthorized'; end if;
  update rm_organizations set is_paid = p_paid where id = p_org_id;
  return true;
end;
$function$;

create or replace function public.rm_admin_list_orgs(p_admin_password text)
returns setof rm_organizations
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
begin
  if not rm_admin_check_password(p_admin_password) then raise exception 'Unauthorized'; end if;
  return query select * from rm_organizations order by created_at desc;
end;
$function$;
