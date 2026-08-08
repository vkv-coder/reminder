-- Notify admin (Telegram, via the existing send-telegram edge function -
-- same one auth.html already calls client-side for new-signup alerts)
-- when an org's trial actually starts (first item created), and again
-- 3 days before it ends (via pg_cron, since this app has no external
-- scheduler like Appointment-'s Apps Script backend).

create or replace function public.rm_notify_trial_started() returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if NEW.trial_started_at is not null and OLD.trial_started_at is null
     and coalesce(NEW.is_demo, false) = false then
    perform net.http_post(
      url := 'https://jqqnnkzozjskziaizajg.supabase.co/functions/v1/send-telegram',
      headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpxcW5ua3pvempza3ppYWl6YWpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI5Mjk1ODAsImV4cCI6MjA4ODUwNTU4MH0.sEYeWnm0dvuw8bLSVnQhqmgV8LB-pELjpuVIa3Us1Gg'),
      body := jsonb_build_object(
        'chat_id', '8507770594',
        'text', '🎯 Free trial started' || chr(10) || 'Org: ' || coalesce(NEW.org_name,'') || chr(10) || 'Email: ' || coalesce(NEW.owner_email,'') || chr(10) || chr(10) || '30-day trial clock is now running.'
      )
    );
  end if;
  return NEW;
end;
$$;

drop trigger if exists rm_organizations_notify_trial_started on rm_organizations;
create trigger rm_organizations_notify_trial_started
after update on rm_organizations
for each row execute function rm_notify_trial_started();

-- ---------- 3-day-before-expiry reminder (owner-facing) ----------
create or replace function public.rm_send_trial_ending_reminders() returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_org record; v_end timestamptz; v_days_left int;
begin
  for v_org in
    select * from rm_organizations
    where status = 'active' and is_paid = false and trial_reminder_sent = false
      and trial_started_at is not null and coalesce(is_demo,false) = false
  loop
    v_end := v_org.trial_started_at + ((30 + v_org.trial_extended_days) || ' days')::interval;
    v_days_left := ceil(extract(epoch from (v_end - now())) / 86400);

    if v_days_left = 3 then
      if v_org.owner_email is not null then
        perform net.http_post(
          url := 'https://telegram-notify.unigoods2026.workers.dev/',
          headers := '{"Content-Type":"application/json"}'::jsonb,
          body := jsonb_build_object(
            'action', 'sendEmail',
            'to', v_org.owner_email,
            'fromName', 'Reminders',
            'subject', 'Your Reminders free trial ends in 3 days',
            'html', '<p>Hi,</p>'
              || '<p>Your organization <b>' || coalesce(v_org.org_name,'') || '</b>''s 30-day free trial ends on ' || to_char(v_end, 'DD Mon YYYY') || '.</p>'
              || '<p>Contact <a href="mailto:vkvcoder.support@gmail.com">vkvcoder.support@gmail.com</a> to extend your trial or move to a paid plan and keep using Reminders without interruption.</p>'
          )
        );
      end if;
      perform net.http_post(
        url := 'https://jqqnnkzozjskziaizajg.supabase.co/functions/v1/send-telegram',
        headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpxcW5ua3pvempza3ppYWl6YWpnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI5Mjk1ODAsImV4cCI6MjA4ODUwNTU4MH0.sEYeWnm0dvuw8bLSVnQhqmgV8LB-pELjpuVIa3Us1Gg'),
        body := jsonb_build_object(
          'chat_id', '8507770594',
          'text', '⏳ ' || coalesce(v_org.org_name,'') || '''s trial ends in 3 days'
        )
      );
      update rm_organizations set trial_reminder_sent = true where id = v_org.id;
    end if;
  end loop;
end;
$$;

-- Runs once daily at 9:00 AM UTC (2:30 PM IST)
select cron.schedule(
  'rm-trial-ending-reminders',
  '0 9 * * *',
  $$select rm_send_trial_ending_reminders();$$
);
