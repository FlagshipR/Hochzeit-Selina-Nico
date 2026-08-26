-- Fotowand für Selina & Nico
-- Einmalig im Supabase SQL-Editor ausführen (Projekt: jglfuixuxqonltromtax)
--
-- Konzept:
--   - Gäste laden Fotos direkt in den Storage-Bucket "hochzeitsfotos" hoch,
--     kein Login nötig (anon darf nur hochladen, nicht löschen/überschreiben).
--   - Pro hochgeladenem Foto wird zusätzlich eine Zeile in der Tabelle
--     "fotos" angelegt (Pfad + Zeitstempel) - darüber liest die Slideshow-
--     Seite die Liste aus, genau wie admin.html die rsvp-Tabelle ausliest.
--   - Löschen können nur Selina & Nico, direkt im Supabase-Dashboard
--     (Storage-Bucket oder Tabelle "fotos") - der anon-Key hat dafür
--     bewusst keine Rechte, damit niemand fremde Fotos löschen kann.

-- 1) Storage-Bucket anlegen (public, damit Fotos ohne Auth angezeigt werden können)
insert into storage.buckets (id, name, public)
values ('hochzeitsfotos', 'hochzeitsfotos', true)
on conflict (id) do nothing;

-- Falls dieser Insert wegen fehlender Rechte im SQL-Editor scheitert:
-- Alternativ im Dashboard unter Storage -> New Bucket, Name "hochzeitsfotos",
-- Public Bucket aktivieren.

-- 2) Upload erlauben (anon darf hochladen, aber nicht lesen/löschen/überschreiben
--    über die Storage-API - das öffentliche Anzeigen läuft separat über die
--    public-URL, die der "public"-Flag oben freischaltet)
create policy "Hochzeitsfotos oeffentlicher Upload"
on storage.objects for insert
to anon
with check (bucket_id = 'hochzeitsfotos');

-- 3) Tabelle für die Foto-Liste (Slideshow + spätere Übersicht lesen daraus,
--    nicht aus der Storage-API - gleiches Muster wie die rsvp-Tabelle)
create table if not exists fotos (
  id uuid primary key default gen_random_uuid(),
  storage_path text not null,
  created_at timestamptz not null default now()
);

alter table fotos enable row level security;

create policy "Fotos oeffentlich eintragen"
on fotos for insert
to anon
with check (true);

create policy "Fotos oeffentlich lesen"
on fotos for select
to anon
using (true);
