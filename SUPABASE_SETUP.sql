-- ============================================================
-- SISTEMA DE CONTROL Y TRAZABILIDAD DE EXPEDIENTES
-- Base de datos: Supabase / PostgreSQL
-- Ejecutar TODO este archivo una sola vez en Supabase > SQL Editor
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.expedientes (
  id uuid primary key default gen_random_uuid(),
  expediente text not null,
  extension text null,
  rd text null,
  serie text not null default 'PAS',
  estado text not null default 'CUSTODIA',
  responsable text not null,
  modalidad text not null default 'FÍSICO',
  fecha_solicitud date null,
  fecha_entrega date null,
  fecha_devolucion date null,
  fecha_reasignacion date null,
  ultimo_folio text null,
  digitalizado text not null default 'NO',
  enlace text null,
  cargo text null,
  acumulado text null,
  observacion text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid null default auth.uid()
);

alter table public.expedientes
  drop constraint if exists expedientes_formato_check;
alter table public.expedientes
  add constraint expedientes_formato_check
  check (expediente ~ '^[0-9]+-[12][0-9]{3}$');

create unique index if not exists expedientes_identificador_unico
  on public.expedientes (expediente, coalesce(extension,''));

create index if not exists expedientes_responsable_idx on public.expedientes(responsable);
create index if not exists expedientes_estado_idx on public.expedientes(estado);
create index if not exists expedientes_fecha_entrega_idx on public.expedientes(fecha_entrega);
create index if not exists expedientes_updated_idx on public.expedientes(updated_at desc);

create table if not exists public.historial_expedientes (
  id uuid primary key default gen_random_uuid(),
  expediente_id uuid not null references public.expedientes(id) on delete cascade,
  expediente text not null,
  extension text null,
  accion text not null,
  desde text null,
  hacia text null,
  cargo text null,
  detalle text null,
  usuario_id uuid null default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists historial_expediente_id_idx on public.historial_expedientes(expediente_id);
create index if not exists historial_created_idx on public.historial_expedientes(created_at desc);

-- Fecha de actualización automática.
create or replace function public.set_expediente_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  return new;
end;
$$;

drop trigger if exists trg_expediente_updated_at on public.expedientes;
create trigger trg_expediente_updated_at
before update on public.expedientes
for each row execute function public.set_expediente_updated_at();

-- Historial automático del expediente.
create or replace function public.registrar_historial_expediente()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, desde, hacia, cargo, detalle)
    values
      (new.id, new.expediente, new.extension, 'REGISTRO DEL EXPEDIENTE', null, new.responsable, new.cargo,
       'Expediente incorporado al sistema.');

    if new.fecha_solicitud is not null then
      insert into public.historial_expedientes
        (expediente_id, expediente, extension, accion, hacia, cargo, detalle)
      values
        (new.id, new.expediente, new.extension, 'SOLICITUD REGISTRADA', new.responsable, new.cargo,
         'Fecha de solicitud: ' || to_char(new.fecha_solicitud,'DD/MM/YYYY'));
    end if;

    if new.fecha_entrega is not null then
      insert into public.historial_expedientes
        (expediente_id, expediente, extension, accion, hacia, cargo, detalle)
      values
        (new.id, new.expediente, new.extension, 'ENTREGA DEL EXPEDIENTE', new.responsable, new.cargo,
         'Fecha de entrega: ' || to_char(new.fecha_entrega,'DD/MM/YYYY'));
    end if;

    if new.fecha_devolucion is not null then
      insert into public.historial_expedientes
        (expediente_id, expediente, extension, accion, desde, hacia, cargo, detalle)
      values
        (new.id, new.expediente, new.extension, 'DEVOLUCIÓN', new.responsable, 'ARCHIVO / CUSTODIA', new.cargo,
         'Fecha de devolución: ' || to_char(new.fecha_devolucion,'DD/MM/YYYY'));
    end if;

    return new;
  end if;

  if old.responsable is distinct from new.responsable then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, desde, hacia, cargo, detalle)
    values
      (new.id, new.expediente, new.extension, 'REASIGNACIÓN / CAMBIO DE UBICACIÓN',
       old.responsable, new.responsable, new.cargo, 'Cambio de responsable o ubicación.');
  end if;

  if old.estado is distinct from new.estado then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, desde, hacia, cargo, detalle)
    values
      (new.id, new.expediente, new.extension, 'CAMBIO DE ESTADO',
       old.estado, new.estado, new.cargo, 'Cambio de estado del expediente.');
  end if;

  if old.fecha_solicitud is distinct from new.fecha_solicitud then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, hacia, cargo, detalle)
    values
      (new.id, new.expediente, new.extension,
       case when old.fecha_solicitud is null then 'SOLICITUD REGISTRADA' else 'ACTUALIZACIÓN DE SOLICITUD' end,
       new.responsable, new.cargo,
       'Fecha de solicitud: ' || coalesce(to_char(old.fecha_solicitud,'DD/MM/YYYY'),'—') ||
       ' → ' || coalesce(to_char(new.fecha_solicitud,'DD/MM/YYYY'),'—'));
  end if;

  if old.fecha_entrega is distinct from new.fecha_entrega then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, desde, hacia, cargo, detalle)
    values
      (new.id, new.expediente, new.extension,
       case when old.fecha_entrega is null then 'ENTREGA DEL EXPEDIENTE' else 'ACTUALIZACIÓN DE ENTREGA' end,
       old.responsable, new.responsable, new.cargo,
       'Fecha de entrega: ' || coalesce(to_char(old.fecha_entrega,'DD/MM/YYYY'),'—') ||
       ' → ' || coalesce(to_char(new.fecha_entrega,'DD/MM/YYYY'),'—'));
  end if;

  if old.fecha_devolucion is distinct from new.fecha_devolucion then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, desde, hacia, cargo, detalle)
    values
      (new.id, new.expediente, new.extension,
       case when old.fecha_devolucion is null then 'DEVOLUCIÓN' else 'ACTUALIZACIÓN DE DEVOLUCIÓN' end,
       new.responsable, 'ARCHIVO / CUSTODIA', new.cargo,
       'Fecha de devolución: ' || coalesce(to_char(old.fecha_devolucion,'DD/MM/YYYY'),'—') ||
       ' → ' || coalesce(to_char(new.fecha_devolucion,'DD/MM/YYYY'),'—'));
  end if;

  if old.fecha_reasignacion is distinct from new.fecha_reasignacion and new.fecha_reasignacion is not null then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, desde, hacia, cargo, detalle)
    values
      (new.id, new.expediente, new.extension, 'FECHA DE REASIGNACIÓN',
       old.responsable, new.responsable, new.cargo,
       'Última reasignación: ' || to_char(new.fecha_reasignacion,'DD/MM/YYYY'));
  end if;

  if old.cargo is distinct from new.cargo and nullif(new.cargo,'') is not null then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, hacia, cargo, detalle)
    values
      (new.id, new.expediente, new.extension, 'CARGO ASOCIADO',
       new.responsable, new.cargo, 'Cargo asociado al expediente.');
  end if;

  if old.ultimo_folio is distinct from new.ultimo_folio and nullif(new.ultimo_folio,'') is not null then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, cargo, detalle)
    values
      (new.id, new.expediente, new.extension, 'ACTUALIZACIÓN DE FOLIO',
       new.cargo, 'Último folio: ' || coalesce(old.ultimo_folio,'—') || ' → ' || new.ultimo_folio);
  end if;

  if old.digitalizado is distinct from new.digitalizado then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, cargo, detalle)
    values
      (new.id, new.expediente, new.extension, 'ACTUALIZACIÓN DE DIGITALIZACIÓN',
       new.cargo, 'Digitalizado: ' || coalesce(old.digitalizado,'—') || ' → ' || coalesce(new.digitalizado,'—'));
  end if;

  if old.observacion is distinct from new.observacion and nullif(new.observacion,'') is not null then
    insert into public.historial_expedientes
      (expediente_id, expediente, extension, accion, cargo, detalle)
    values
      (new.id, new.expediente, new.extension, 'OBSERVACIÓN ACTUALIZADA',
       new.cargo, new.observacion);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_historial_expediente on public.expedientes;
create trigger trg_historial_expediente
after insert or update on public.expedientes
for each row execute function public.registrar_historial_expediente();

-- Días hábiles (lunes a viernes; no descuenta feriados).
create or replace function public.dias_habiles(fecha_inicio date, fecha_fin date default current_date)
returns integer
language sql
stable
set search_path = public
as $$
  select case
    when fecha_inicio is null then 0
    when coalesce(fecha_fin,current_date) < fecha_inicio then 0
    else count(*)::integer
  end
  from generate_series(fecha_inicio, coalesce(fecha_fin,current_date), interval '1 day') d
  where extract(isodow from d) between 1 and 5;
$$;

-- Resumen por responsable para que el panel no tenga que descargar toda la base.
create or replace function public.resumen_responsables()
returns table(
  responsable text,
  total bigint,
  pendientes bigint,
  en_prestamo bigint,
  alertas bigint
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    e.responsable,
    count(*) as total,
    count(*) filter (where e.fecha_devolucion is null and e.estado <> 'DEVUELTO') as pendientes,
    count(*) filter (where e.estado = 'EN PRÉSTAMO') as en_prestamo,
    count(*) filter (
      where e.fecha_devolucion is null
        and e.modalidad <> 'COPIA DIGITAL'
        and e.fecha_entrega is not null
        and public.dias_habiles(e.fecha_entrega,current_date) > 30
    ) as alertas
  from public.expedientes e
  group by e.responsable
  order by e.responsable;
$$;

-- ============================================================
-- SEGURIDAD
-- Todos los usuarios deben iniciar sesión con Supabase Auth.
-- ============================================================

alter table public.expedientes enable row level security;
alter table public.historial_expedientes enable row level security;

grant usage on schema public to authenticated;

revoke all on public.expedientes from anon;
revoke all on public.historial_expedientes from anon;

grant select, insert, update on public.expedientes to authenticated;
grant select, insert on public.historial_expedientes to authenticated;
grant execute on function public.resumen_responsables() to authenticated;
grant execute on function public.dias_habiles(date,date) to authenticated;

drop policy if exists "expedientes_select_authenticated" on public.expedientes;
create policy "expedientes_select_authenticated"
on public.expedientes for select
to authenticated
using (true);

drop policy if exists "expedientes_insert_authenticated" on public.expedientes;
create policy "expedientes_insert_authenticated"
on public.expedientes for insert
to authenticated
with check (true);

drop policy if exists "expedientes_update_authenticated" on public.expedientes;
create policy "expedientes_update_authenticated"
on public.expedientes for update
to authenticated
using (true)
with check (true);

drop policy if exists "historial_select_authenticated" on public.historial_expedientes;
create policy "historial_select_authenticated"
on public.historial_expedientes for select
to authenticated
using (true);

drop policy if exists "historial_insert_authenticated" on public.historial_expedientes;
create policy "historial_insert_authenticated"
on public.historial_expedientes for insert
to authenticated
with check (true);

-- No se otorga UPDATE ni DELETE sobre historial: preserva la trazabilidad.
