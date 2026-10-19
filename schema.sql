-- =====================================================================
--  منصة الطلبات الاستثنائية — كلية الشريعة
--  المرحلة الأولى: الجداول · الصلاحيات (RLS) · دوال التقديم والتتبع · التخزين
--  طريقة التشغيل: Supabase → SQL Editor → الصق الملف كاملاً → Run
--  الملف آمن لإعادة التشغيل (idempotent)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) الموظفون والأدوار
--    admin    : مدير النظام
--    office   : موظف المكتب (استلام ومراجعة ورفع للعميد)
--    dean     : العميد (التوجيه)
--    referral : جهة محال لها (قسم / وكالة) — ترى المحال لها فقط
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  full_name      text not null,
  role           text not null check (role in ('admin','office','dean','referral')),
  referral_unit  text,
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

create or replace function public.get_my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function public.get_my_unit() returns text
language sql stable security definer set search_path = public as $$
  select referral_unit from public.profiles where id = auth.uid() and active
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active)
$$;

-- ---------------------------------------------------------------------
-- 2) السنة الهجرية (الخوارزمية الجدولية) — لترقيم الطلبات EX-1448-0001
-- ---------------------------------------------------------------------
create or replace function public.hijri_year(d date) returns int
language plpgsql immutable set search_path = '' as $$
declare jd int; l int; n int; j int;
begin
  jd := to_char(d, 'J')::int;
  l  := jd - 1948440 + 10632;
  n  := (l - 1) / 10631;
  l  := l - 10631 * n + 354;
  j  := ((10985 - l) / 5316) * ((50 * l) / 17719) + (l / 5670) * ((43 * l) / 15238);
  l  := l - ((30 - j) / 15) * ((17719 * j) / 50) - (j / 16) * ((15238 * j) / 43) + 29;
  return 30 * n + j - 30;
end $$;

create table if not exists public.request_counters (
  hijri_year int primary key,
  last_no    int not null default 0
);

-- ---------------------------------------------------------------------
-- 3) الطلبات
-- ---------------------------------------------------------------------
create table if not exists public.requests (
  id              uuid primary key default gen_random_uuid(),
  ref_no          text unique not null,   -- مثل 1448/0001

  -- بيانات الطالب
  student_name    text not null,
  university_id   text not null check (university_id ~ '^[0-9]{6,10}$'),
  student_email   text generated always as (university_id || '@qu.edu.sa') stored,
  gender          text not null check (gender in ('male','female')),
  level           text not null check (level in ('bachelor','master','phd')),
  department      text not null,
  mobile          text not null check (mobile ~ '^05[0-9]{8}$'),

  -- الطلب
  category        text not null check (category in ('registration','exams','postpone','plan','other')),
  summary         text not null check (char_length(summary) between 5 and 300),
  bypass_reason   text not null check (bypass_reason in ('deadline','unavailable','technical','other')),
  bypass_other    text,
  justification   text not null check (char_length(justification) between 10 and 3000),

  -- المعالجة
  status          text not null default 'new'
                  check (status in ('new','in_review','needs_info','at_dean','referred','approved','rejected','closed')),
  office_note     text,                -- داخلية: ملاحظة المكتب للعميد
  dean_decision   text check (dean_decision in ('approved','rejected','referred','needs_info')),
  dean_note       text,                -- داخلية: توجيه العميد
  referred_to     text,
  student_message text,                -- تظهر للطالب في صفحة التتبع

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists requests_status_idx  on public.requests (status);
create index if not exists requests_created_idx on public.requests (created_at desc);
create index if not exists requests_uid_idx     on public.requests (university_id);

create table if not exists public.request_files (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.requests(id) on delete cascade,
  path        text not null unique,
  name        text not null,
  size        bigint,
  mime        text,
  uploaded_by uuid,                   -- null = الطالب
  created_at  timestamptz not null default now()
);

-- سجل الطلب: كل حركة (is_public = تظهر للطالب)
create table if not exists public.request_events (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.requests(id) on delete cascade,
  actor       uuid,
  action      text not null,          -- submitted | status | note | referral ...
  from_status text,
  to_status   text,
  note        text,
  is_public   boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists events_request_idx on public.request_events (request_id, created_at);

-- تسجيل تلقائي لأي تغيير حالة + تحديث updated_at
create or replace function public.tg_requests_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if new.status is distinct from old.status then
    insert into public.request_events (request_id, actor, action, from_status, to_status, is_public)
    values (new.id, auth.uid(), 'status', old.status, new.status, true);
  end if;
  return new;
end $$;

drop trigger if exists requests_audit on public.requests;
create trigger requests_audit before update on public.requests
for each row execute function public.tg_requests_audit();

-- ---------------------------------------------------------------------
-- 4) تقديم الطلب (للطالب — بدون تسجيل دخول)
-- ---------------------------------------------------------------------
create or replace function public.submit_request(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_year   int := public.hijri_year((now() at time zone 'Asia/Riyadh')::date);
  v_seq    int;
  v_ref    text;
  v_id     uuid;
  v_recent int;
  f        jsonb;
begin
  -- حد أقصى 3 طلبات لكل رقم جامعي خلال 24 ساعة
  select count(*) into v_recent from public.requests
   where university_id = p->>'university_id' and created_at > now() - interval '24 hours';
  if v_recent >= 3 then raise exception 'RATE_LIMIT'; end if;

  if jsonb_typeof(p->'files') = 'array' and jsonb_array_length(p->'files') > 5 then
    raise exception 'TOO_MANY_FILES';
  end if;

  insert into public.request_counters (hijri_year, last_no) values (v_year, 1)
  on conflict (hijri_year) do update set last_no = public.request_counters.last_no + 1
  returning last_no into v_seq;

  v_ref := 'EX-' || v_year || '-' || lpad(v_seq::text, 4, '0');

  insert into public.requests (
    ref_no, student_name, university_id, gender, level, department, mobile,
    category, summary, bypass_reason, bypass_other, justification
  ) values (
    v_ref,
    trim(p->>'student_name'),
    trim(p->>'university_id'),
    p->>'gender',
    p->>'level',
    trim(p->>'department'),
    trim(p->>'mobile'),
    p->>'category',
    trim(p->>'summary'),
    p->>'bypass_reason',
    nullif(trim(coalesce(p->>'bypass_other','')), ''),
    trim(p->>'justification')
  ) returning id into v_id;

  if jsonb_typeof(p->'files') = 'array' then
    for f in select * from jsonb_array_elements(p->'files') loop
      if (f->>'path') !~ '^incoming/[0-9a-f-]{36}/' then raise exception 'BAD_FILE_PATH'; end if;
      if not exists (select 1 from storage.objects
                      where bucket_id = 'request-files' and name = f->>'path') then
        raise exception 'FILE_NOT_FOUND';
      end if;
      insert into public.request_files (request_id, path, name, size, mime)
      values (v_id, f->>'path', left(coalesce(f->>'name','مرفق'), 200),
              nullif(f->>'size','')::bigint, f->>'mime');
    end loop;
  end if;

  insert into public.request_events (request_id, action, to_status, is_public)
  values (v_id, 'submitted', 'new', true);

  return json_build_object('ref_no', v_ref, 'created_at', now());
end $$;

-- ---------------------------------------------------------------------
-- 5) تتبع الطلب (للطالب): الرقم المرجعي + آخر 4 أرقام من الجوال
--    لا يُرجع أي ملاحظات داخلية — الحالة والسجل العام ورسالة الطالب فقط
-- ---------------------------------------------------------------------
create or replace function public.track_request(p_ref text, p_last4 text) returns json
language plpgsql stable security definer set search_path = public as $$
declare r public.requests%rowtype;
begin
  select * into r from public.requests
   where ref_no = upper(trim(p_ref)) and right(mobile, 4) = trim(p_last4);
  if not found then return null; end if;

  return json_build_object(
    'ref_no', r.ref_no,
    'status', r.status,
    'category', r.category,
    'summary', r.summary,
    'created_at', r.created_at,
    'updated_at', r.updated_at,
    'student_message', r.student_message,
    'events', coalesce((
      select json_agg(json_build_object('action', e.action, 'to_status', e.to_status,
                                        'created_at', e.created_at) order by e.created_at)
        from public.request_events e
       where e.request_id = r.id and e.is_public), '[]'::json)
  );
end $$;

revoke all on function public.submit_request(jsonb)       from public;
revoke all on function public.track_request(text, text)   from public;
grant execute on function public.submit_request(jsonb)     to anon, authenticated;
grant execute on function public.track_request(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6) سياسات الأمان (RLS) — الطالب لا يصل للجداول إطلاقاً، فقط عبر الدالتين
-- ---------------------------------------------------------------------
alter table public.profiles         enable row level security;
alter table public.requests         enable row level security;
alter table public.request_files    enable row level security;
alter table public.request_events   enable row level security;
alter table public.request_counters enable row level security;

-- profiles
drop policy if exists profiles_self_read  on public.profiles;
drop policy if exists profiles_admin_all  on public.profiles;
create policy profiles_self_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff());
create policy profiles_admin_all on public.profiles for all to authenticated
  using (public.get_my_role() = 'admin') with check (public.get_my_role() = 'admin');

-- requests
drop policy if exists requests_staff_read   on public.requests;
drop policy if exists requests_staff_update on public.requests;
create policy requests_staff_read on public.requests for select to authenticated
  using (
    public.get_my_role() in ('admin','office','dean')
    or (public.get_my_role() = 'referral' and referred_to = public.get_my_unit())
  );
create policy requests_staff_update on public.requests for update to authenticated
  using (public.get_my_role() in ('admin','office','dean'))
  with check (public.get_my_role() in ('admin','office','dean'));

-- request_files (تتبع صلاحية قراءة الطلب نفسه)
drop policy if exists files_staff_read   on public.request_files;
drop policy if exists files_staff_insert on public.request_files;
create policy files_staff_read on public.request_files for select to authenticated
  using (exists (select 1 from public.requests r where r.id = request_id));
create policy files_staff_insert on public.request_files for insert to authenticated
  with check (public.is_staff() and uploaded_by = auth.uid());

-- request_events
drop policy if exists events_staff_read   on public.request_events;
drop policy if exists events_staff_insert on public.request_events;
create policy events_staff_read on public.request_events for select to authenticated
  using (exists (select 1 from public.requests r where r.id = request_id));
create policy events_staff_insert on public.request_events for insert to authenticated
  with check (public.is_staff() and actor = auth.uid());

-- ---------------------------------------------------------------------
-- 7) التخزين: حاوية خاصة (غير عامة) للمرفقات
--    الطالب يرفع فقط داخل incoming/ ولا يستطيع القراءة أو العرض
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('request-files', 'request-files', false, 10485760, array[
  'application/pdf','image/jpeg','image/png','image/webp','image/heic','image/heif',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "exreq upload incoming" on storage.objects;
drop policy if exists "exreq staff read"      on storage.objects;
drop policy if exists "exreq staff upload"    on storage.objects;

create policy "exreq upload incoming" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'request-files' and (storage.foldername(name))[1] = 'incoming');

create policy "exreq staff read" on storage.objects for select to authenticated
  using (bucket_id = 'request-files' and public.is_staff());

create policy "exreq staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'request-files' and public.is_staff());

-- =====================================================================
-- بعد التشغيل: أضف الموظفين
--   Authentication → Users → Add user (بريد + كلمة مرور)
--   ثم:
--   insert into public.profiles (id, full_name, role)
--   values ('<user-uuid>', 'الاسم', 'admin');   -- أو office / dean / referral
-- =====================================================================

-- =====================================================================
-- تحديث: طلب قائم واحد لكل طالب (مطبّق على قاعدة البيانات)
--   - submit_request ترفض بـ OPEN_REQUEST إذا كان للطالب طلب حالته:
--     new / in_review / needs_info / at_dean / referred
--   - قفل استشاري على الرقم الجامعي يمنع الإرسال المزدوج المتزامن
--   - check_open_request(uid, mobile): فحص مبكر بعد الخطوة الأولى،
--     يُرجع رقم الطلب فقط إذا تطابق الجوال أيضاً (لا يكشف طلبات الآخرين)
--   النص الكامل للدالتين: انظر migration «part7_one_open_request_per_student»
--   في Supabase → Database → Migrations
-- =====================================================================

-- تحديث: صيغة رقم الطلب صارت أرقاماً فقط 1448/0001 (بدل EX-1448-0001)
--   normalize_ref() تقبل: 1448/0001 · 1448-1 · 14480001 · EX-1448-0001
--   انظر migration «part9_numeric_reference_numbers»

-- تحديث (المرحلة الثانية):
--   حالات إضافية: reserved (متحفظ) · withdrawn (مسحوب)
--   دوال المكتب والعميد: req_take · req_request_info · req_forward · req_decide · req_return
--                        req_close · req_update_info · req_note · req_reopen · set_delegation
--   دوال الطالب: student_complete (رد + مرفقات استكمال) · student_withdraw (فقط قبل استلام المكتب للطلب)
--   جدول settings: لقب العميد واسمه ومسماه للنموذج المطبوع
--   انظر migrations: p2_* و p3_* في Supabase → Database → Migrations
