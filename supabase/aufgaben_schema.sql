-- Aufgabenliste für Selina & Nico
-- Einmalig im Supabase SQL-Editor ausführen (Projekt: jglfuixuxqonltromtax)
--
-- Konzept:
--   - Jede Person (Helfer, Selina, Nico) bekommt ein eigenes Passwort (personen.passwort).
--   - is_master = true  -> Selina & Nico: sehen alles, dürfen alles löschen/bearbeiten.
--   - Alle eingeloggten Personen sehen die komplette Aufgabenliste (Transparenz),
--     dürfen aber nur eigene (selbst angelegte) Aufgaben löschen/bearbeiten.
--   - Die eigentliche Berechtigungsprüfung passiert serverseitig in den Functions
--     unten (security definer), nicht nur im Frontend-JS. Das Passwort der
--     Personen wird dem Browser dabei nie direkt preisgegeben (kein SELECT auf
--     personen.passwort für anon).

create extension if not exists pgcrypto;

create table if not exists personen (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  passwort text not null unique,
  is_master boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists aufgaben (
  id uuid primary key default gen_random_uuid(),
  titel text not null,
  beschreibung text,
  zugewiesen_an uuid references personen(id) on delete set null,
  status text not null default 'offen' check (status in ('offen', 'erledigt')),
  erstellt_von uuid not null references personen(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table personen enable row level security;
alter table aufgaben enable row level security;
-- Bewusst keine Policies für anon auf den Rohtabellen -> Zugriff nur über
-- die Views/Functions unten.

-- Öffentliche Sicht auf Personen ohne Passwort (für Dropdown "zugewiesen an")
create or replace view personen_public as
  select id, name, is_master from personen;
grant select on personen_public to anon;

-- Sicht auf Aufgaben mit aufgelösten Namen. NICHT an anon freigegeben,
-- da sonst jeder mit dem anon-Key alle Aufgaben aller Personen abrufen
-- könnte, egal was die App im Frontend anzeigt. Zugriff nur über
-- list_aufgaben() unten.
create or replace view aufgaben_view as
  select
    a.id, a.titel, a.beschreibung, a.status, a.created_at,
    p1.id as zugewiesen_an_id, p1.name as zugewiesen_an_name,
    p2.id as erstellt_von_id, p2.name as erstellt_von_name
  from aufgaben a
  left join personen p1 on p1.id = a.zugewiesen_an
  join personen p2 on p2.id = a.erstellt_von;
revoke select on aufgaben_view from anon;

-- Aufgaben auflisten: Master sehen alle, alle anderen nur Aufgaben, die
-- sie selbst angelegt haben oder die ihnen zugewiesen sind.
create or replace function list_aufgaben(p_passwort text)
returns table(
  id uuid, titel text, beschreibung text, status text, created_at timestamptz,
  zugewiesen_an_id uuid, zugewiesen_an_name text,
  erstellt_von_id uuid, erstellt_von_name text
)
language plpgsql security definer set search_path = public
as $$
declare
  v_person_id uuid;
  v_is_master boolean;
begin
  select personen.id, personen.is_master into v_person_id, v_is_master
    from personen where passwort = p_passwort;
  if v_person_id is null then
    raise exception 'Ungültiges Passwort';
  end if;

  if v_is_master then
    return query select * from aufgaben_view order by aufgaben_view.created_at desc;
  else
    return query select * from aufgaben_view
      where aufgaben_view.erstellt_von_id = v_person_id or aufgaben_view.zugewiesen_an_id = v_person_id
      order by aufgaben_view.created_at desc;
  end if;
end;
$$;
grant execute on function list_aufgaben(text) to anon;

-- Login: Passwort -> Person (nur bei korrektem Passwort wird was zurückgegeben)
create or replace function login_person(p_passwort text)
returns table(id uuid, name text, is_master boolean)
language sql security definer set search_path = public
as $$
  select id, name, is_master from personen where passwort = p_passwort;
$$;
grant execute on function login_person(text) to anon;

-- Aufgabe anlegen (jede eingeloggte Person darf das)
create or replace function add_aufgabe(
  p_passwort text, p_titel text, p_beschreibung text, p_zugewiesen_an uuid
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_person_id uuid;
  v_new_id uuid;
begin
  select id into v_person_id from personen where passwort = p_passwort;
  if v_person_id is null then
    raise exception 'Ungültiges Passwort';
  end if;

  insert into aufgaben (titel, beschreibung, zugewiesen_an, erstellt_von)
  values (p_titel, nullif(p_beschreibung, ''), p_zugewiesen_an, v_person_id)
  returning id into v_new_id;

  return v_new_id;
end;
$$;
grant execute on function add_aufgabe(text, text, text, uuid) to anon;

-- Aufgabe löschen: nur Ersteller der Aufgabe oder Master
create or replace function delete_aufgabe(p_passwort text, p_aufgabe_id uuid)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_person_id uuid;
  v_is_master boolean;
  v_ersteller uuid;
begin
  select id, is_master into v_person_id, v_is_master from personen where passwort = p_passwort;
  if v_person_id is null then
    raise exception 'Ungültiges Passwort';
  end if;

  select erstellt_von into v_ersteller from aufgaben where id = p_aufgabe_id;
  if v_ersteller is null then
    return false;
  end if;

  if v_is_master or v_ersteller = v_person_id then
    delete from aufgaben where id = p_aufgabe_id;
    return true;
  else
    raise exception 'Keine Berechtigung, diese Aufgabe zu löschen';
  end if;
end;
$$;
grant execute on function delete_aufgabe(text, uuid) to anon;

-- Status ändern (offen/erledigt): Ersteller, zugewiesene Person oder Master
create or replace function update_aufgabe_status(p_passwort text, p_aufgabe_id uuid, p_status text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_person_id uuid;
  v_is_master boolean;
  v_ersteller uuid;
  v_zugewiesen uuid;
begin
  if p_status not in ('offen', 'erledigt') then
    raise exception 'Ungültiger Status';
  end if;

  select id, is_master into v_person_id, v_is_master from personen where passwort = p_passwort;
  if v_person_id is null then
    raise exception 'Ungültiges Passwort';
  end if;

  select erstellt_von, zugewiesen_an into v_ersteller, v_zugewiesen from aufgaben where id = p_aufgabe_id;

  if v_is_master or v_ersteller = v_person_id or v_zugewiesen = v_person_id then
    update aufgaben set status = p_status where id = p_aufgabe_id;
    return true;
  else
    raise exception 'Keine Berechtigung';
  end if;
end;
$$;
grant execute on function update_aufgabe_status(text, uuid, text) to anon;

-- Neue Person anlegen: nur Master dürfen das. So können Selina & Nico
-- Helfer direkt auf der Seite anlegen, ohne das Supabase-Dashboard oder
-- git anzufassen (Passwörter landen dadurch nie im Repo/in der Git-Historie).
create or replace function add_person(
  p_passwort_master text, p_name text, p_neues_passwort text, p_is_master boolean default false
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_is_master boolean;
  v_new_id uuid;
begin
  select is_master into v_is_master from personen where passwort = p_passwort_master;
  if v_is_master is null then
    raise exception 'Ungültiges Passwort';
  end if;
  if not v_is_master then
    raise exception 'Keine Berechtigung, Personen anzulegen';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception 'Name darf nicht leer sein';
  end if;
  if p_neues_passwort is null or length(p_neues_passwort) < 4 then
    raise exception 'Passwort muss mindestens 4 Zeichen haben';
  end if;

  insert into personen (name, passwort, is_master)
  values (trim(p_name), p_neues_passwort, coalesce(p_is_master, false))
  returning id into v_new_id;

  return v_new_id;
exception
  when unique_violation then
    raise exception 'Dieses Passwort ist schon vergeben, bitte ein anderes wählen';
end;
$$;
grant execute on function add_person(text, text, text, boolean) to anon;

-- Person löschen: nur Master. Der letzte Master kann sich nicht selbst
-- aussperren -> ein Master kann nicht gelöscht werden, solange er der
-- einzige ist.
create or replace function delete_person(p_passwort_master text, p_person_id uuid)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_is_master boolean;
  v_target_is_master boolean;
  v_master_count int;
begin
  select is_master into v_is_master from personen where passwort = p_passwort_master;
  if v_is_master is null then
    raise exception 'Ungültiges Passwort';
  end if;
  if not v_is_master then
    raise exception 'Keine Berechtigung, Personen zu löschen';
  end if;

  select is_master into v_target_is_master from personen where id = p_person_id;
  if v_target_is_master is null then
    return false;
  end if;

  if v_target_is_master then
    select count(*) into v_master_count from personen where is_master;
    if v_master_count <= 1 then
      raise exception 'Der letzte Master kann nicht gelöscht werden';
    end if;
  end if;

  delete from personen where id = p_person_id;
  return true;
end;
$$;
grant execute on function delete_person(text, uuid) to anon;

-- Passwort einer Person zurücksetzen: nur Master (z.B. wenn jemand sein
-- Passwort vergessen hat).
create or replace function reset_person_passwort(p_passwort_master text, p_person_id uuid, p_neues_passwort text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_is_master boolean;
begin
  select is_master into v_is_master from personen where passwort = p_passwort_master;
  if v_is_master is null then
    raise exception 'Ungültiges Passwort';
  end if;
  if not v_is_master then
    raise exception 'Keine Berechtigung';
  end if;
  if p_neues_passwort is null or length(p_neues_passwort) < 4 then
    raise exception 'Passwort muss mindestens 4 Zeichen haben';
  end if;

  update personen set passwort = p_neues_passwort where id = p_person_id;
  return found;
exception
  when unique_violation then
    raise exception 'Dieses Passwort ist schon vergeben, bitte ein anderes wählen';
end;
$$;
grant execute on function reset_person_passwort(text, uuid, text) to anon;

-- Einmaliger Bootstrap: die ersten beiden Master-Accounts müssen einmalig
-- per SQL angelegt werden (Henne-Ei-Problem: add_person() setzt ja schon
-- einen eingeloggten Master voraus). Passwörter unten ändern und danach
-- diesen Block NICHT erneut ausführen. Alle weiteren Personen (Helfer,
-- weitere Master) danach bequem über den Bereich "Personen verwalten"
-- auf helfer-der-liebe.html anlegen.
insert into personen (name, passwort, is_master) values
  ('Selina', 'Blume42Kranz', true),
  ('Nico',   'Feier17Tanz',  true)
on conflict (passwort) do nothing;
