-- Emails the org owner when their rm_organizations.status flips to 'active'
-- (the field checked at dashboard.html init() that unlocks login — see
-- orgRow.status !== 'active' redirecting back to auth.html).
-- Previously the owner was only notified via Telegram, and approval itself
-- happens via a manual status edit in Supabase Studio with no application
-- code path involved. Same pattern as derasar-boli/DealLagi — shared
-- Cloudflare Worker email relay (telegram-notify.unigoods2026.workers.dev,
-- action:"sendEmail"), no new API key/secret needed.

create or replace function rm_notify_approval() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'active' and OLD.status is distinct from 'active'
     and coalesce(NEW.is_demo, false) = false then
    if NEW.owner_email is not null then
      perform net.http_post(
        url := 'https://telegram-notify.unigoods2026.workers.dev/',
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := jsonb_build_object(
          'action', 'sendEmail',
          'to', NEW.owner_email,
          'subject', 'Your Reminders account is approved',
          'html', '<p>Hi,</p>'
            || '<p>Your organization <b>' || coalesce(NEW.org_name, '') || '</b> has been approved on Reminders. You can now log in and start using the app:</p>'
            || '<p><a href="https://reminders.anyapps.in">https://reminders.anyapps.in</a></p>'
            || '<p style="font-size:13px;color:#666;">Questions? Contact vkvcoder.support@gmail.com</p>'
        )
      );
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists rm_organizations_notify_approval on rm_organizations;
create trigger rm_organizations_notify_approval
after update on rm_organizations
for each row execute function rm_notify_approval();
