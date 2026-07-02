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

-- Öffentliche Sicht auf Aufgaben mit aufgelösten Namen
create or replace view aufgaben_view as
  select
    a.id, a.titel, a.beschreibung, a.status, a.created_at,
    p1.id as zugewiesen_an_id, p1.name as zugewiesen_an_name,
    p2.id as erstellt_von_id, p2.name as erstellt_von_name
  from aufgaben a
  left join personen p1 on p1.id = a.zugewiesen_an
  join personen p2 on p2.id = a.erstellt_von;
grant select on aufgaben_view to anon;

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

-- Beispiel-Personen anlegen (Passwörter danach im Supabase Table Editor
-- individuell anpassen und an die jeweilige Person weitergeben):
-- insert into personen (name, passwort, is_master) values
--   ('Selina', 'ÄNDERN-selina', true),
--   ('Nico',   'ÄNDERN-nico',   true),
--   ('Julia',  'ÄNDERN-julia',  false);
