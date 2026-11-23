-- OPERATIVO CUMPLEAÑOS DE GERA · Ejecutar COMPLETO en Supabase > SQL Editor
-- ANTES DE EJECUTAR: cambia CAMBIA@TU-CORREO.COM por tu correo (el de tu usuario admin).

create or replace function public.is_admin() returns boolean
language sql stable as $$ select lower(coalesce(auth.jwt()->>'email','')) = lower('bgerardo@outlook.com') $$;

create or replace function public.norm(t text) returns text
language sql immutable as $$ select regexp_replace(translate(lower(trim(t)),'áéíóúüñ','aeiouun'),'\s+',' ','g') $$;

create table public.guests(
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 120),
  name_norm text generated always as (public.norm(name)) stored unique,
  phone text,
  status text not null default 'pendiente' check (status in ('pendiente','confirmado','no_asistira')),
  companion_name text check (char_length(companion_name) <= 120),
  comments text check (char_length(comments) <= 500),
  responded_at timestamptz,
  response_count int not null default 0,
  needs_review boolean not null default false,  -- true = respondió alguien que no está en tu lista
  created_at timestamptz not null default now()
);
create table public.rsvp_log(created_at timestamptz not null default now());

alter table public.guests enable row level security;
alter table public.rsvp_log enable row level security;
revoke all on public.guests, public.rsvp_log from anon, authenticated;
grant select, insert, update, delete on public.guests to authenticated;
create policy admin_all on public.guests for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Único punto de entrada público: valida en servidor, evita duplicados, limita spam.
create or replace function public.submit_rsvp(p_name text, p_attends boolean, p_companion boolean,
  p_companion_name text, p_comments text, p_hp text default '')
returns json language plpgsql security definer set search_path = public as $$
declare n text := public.norm(p_name); g public.guests;
        cn text := nullif(trim(coalesce(p_companion_name,'')),'');
        st text := case when p_attends then 'confirmado' else 'no_asistira' end;
begin
  if coalesce(p_hp,'') <> '' then return json_build_object('ok', true); end if; -- trampa para bots
  if p_name is null or p_attends is null or char_length(trim(p_name)) < 2 or char_length(p_name) > 120
     or char_length(coalesce(p_comments,'')) > 500 or char_length(coalesce(cn,'')) > 120
     then raise exception 'datos invalidos'; end if;
  if p_attends and coalesce(p_companion,false) and cn is null then raise exception 'falta acompanante'; end if;
  if not p_attends or not coalesce(p_companion,false) then cn := null; end if;
  delete from rsvp_log where created_at < now() - interval '1 hour';
  if (select count(*) from rsvp_log where created_at > now() - interval '1 minute') >= 20
     then raise exception 'demasiados envios'; end if;
  insert into rsvp_log default values;
  select * into g from guests where name_norm = n for update;
  if found then
    if g.response_count >= 5 then raise exception 'limite de correcciones'; end if;
    update guests set status = st, companion_name = cn, comments = nullif(trim(p_comments),''),
      responded_at = now(), response_count = response_count + 1 where id = g.id;
  else
    insert into guests(name, status, companion_name, comments, responded_at, response_count, needs_review)
    values (trim(p_name), st, cn, nullif(trim(p_comments),''), now(), 1, true);
  end if;
  return json_build_object('ok', true);
end $$;
revoke all on function public.submit_rsvp from public;
grant execute on function public.submit_rsvp to anon, authenticated;
