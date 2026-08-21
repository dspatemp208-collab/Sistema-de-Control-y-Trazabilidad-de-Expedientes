-- ============================================================
-- MIGRACIÓN: CARGOS PERSISTENTES
-- Ejecutar UNA SOLA VEZ en Supabase > SQL Editor > New query > Run
-- No borra expedientes ni historial existentes.
-- ============================================================

create table if not exists public.cargos (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  solicitante text not null,
  fecha date not null default current_date,
  observacion text null,
  created_by uuid null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.cargo_expedientes (
  cargo_id uuid not null references public.cargos(id) on delete cascade,
  expediente_id uuid not null references public.expedientes(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (cargo_id, expediente_id)
);

create index if not exists cargo_expedientes_expediente_idx
  on public.cargo_expedientes(expediente_id);

-- Recupera cargos antiguos desde el historial.
-- El campo "hacia" contiene el responsable que tenía el expediente cuando se asoció el cargo.
insert into public.cargos(numero, solicitante, fecha, observacion)
select
  trim(h.cargo) as numero,
  min(trim(h.hacia)) as solicitante,
  min(h.created_at)::date as fecha,
  null
from public.historial_expedientes h
where h.accion = 'CARGO ASOCIADO'
  and nullif(trim(h.cargo),'') is not null
  and nullif(trim(h.hacia),'') is not null
group by trim(h.cargo)
having count(distinct trim(h.hacia)) = 1
on conflict (numero) do nothing;

-- Fallback para cargos que no tengan evento recuperable en historial,
-- siempre que todos sus expedientes actuales tengan el mismo responsable.
insert into public.cargos(numero, solicitante, fecha, observacion)
select
  trim(e.cargo) as numero,
  min(trim(e.responsable)) as solicitante,
  coalesce(min(e.fecha_entrega), current_date) as fecha,
  null
from public.expedientes e
where nullif(trim(e.cargo),'') is not null
  and not exists (
    select 1 from public.cargos c where c.numero = trim(e.cargo)
  )
group by trim(e.cargo)
having count(distinct trim(e.responsable)) = 1
on conflict (numero) do nothing;

-- Relaciona los cargos actuales con sus expedientes.
insert into public.cargo_expedientes(cargo_id, expediente_id)
select c.id, e.id
from public.expedientes e
join public.cargos c on c.numero = trim(e.cargo)
where nullif(trim(e.cargo),'') is not null
on conflict do nothing;

-- Función transaccional: el encabezado del cargo queda fijo.
create or replace function public.crear_cargo_fijo(
  p_numero text,
  p_solicitante text,
  p_fecha date,
  p_observacion text,
  p_expediente_ids uuid[]
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid;
  v_cargo public.cargos%rowtype;
begin
  if nullif(trim(p_numero),'') is null then
    raise exception 'El número de cargo es obligatorio';
  end if;

  if nullif(trim(p_solicitante),'') is null then
    raise exception 'El solicitante es obligatorio';
  end if;

  select * into v_cargo
  from public.cargos
  where numero = trim(p_numero);

  if found then
    -- Número, solicitante y fecha quedan FIJOS.
    if v_cargo.solicitante is distinct from trim(p_solicitante) then
      raise exception 'El cargo % ya pertenece al solicitante % y no puede modificarse',
        v_cargo.numero, v_cargo.solicitante;
    end if;

    v_id := v_cargo.id;
  else
    insert into public.cargos(numero, solicitante, fecha, observacion)
    values (
      trim(p_numero),
      trim(p_solicitante),
      coalesce(p_fecha,current_date),
      nullif(trim(p_observacion),'')
    )
    returning id into v_id;
  end if;

  insert into public.cargo_expedientes(cargo_id, expediente_id)
  select v_id, x
  from unnest(p_expediente_ids) as x
  on conflict do nothing;

  update public.expedientes
  set cargo = trim(p_numero)
  where id = any(p_expediente_ids);

  return v_id;
end;
$$;

alter table public.cargos enable row level security;
alter table public.cargo_expedientes enable row level security;

grant select, insert on public.cargos to authenticated;
grant select, insert on public.cargo_expedientes to authenticated;
grant execute on function public.crear_cargo_fijo(text,text,date,text,uuid[]) to authenticated;

drop policy if exists "cargos_select_authenticated" on public.cargos;
create policy "cargos_select_authenticated"
on public.cargos for select
to authenticated
using (true);

drop policy if exists "cargos_insert_authenticated" on public.cargos;
create policy "cargos_insert_authenticated"
on public.cargos for insert
to authenticated
with check (true);

drop policy if exists "cargo_expedientes_select_authenticated" on public.cargo_expedientes;
create policy "cargo_expedientes_select_authenticated"
on public.cargo_expedientes for select
to authenticated
using (true);

drop policy if exists "cargo_expedientes_insert_authenticated" on public.cargo_expedientes;
create policy "cargo_expedientes_insert_authenticated"
on public.cargo_expedientes for insert
to authenticated
with check (true);

-- No se otorga UPDATE ni DELETE en cargos:
-- el número, solicitante y fecha originales quedan preservados.
