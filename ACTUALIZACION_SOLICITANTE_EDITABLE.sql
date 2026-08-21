-- ============================================================
-- ACTUALIZACIÓN: SOLICITANTE EDITABLE EN LOS CARGOS
-- Ejecutar UNA SOLA VEZ en Supabase > SQL Editor.
-- NO borra expedientes, cargos ni historial.
-- El NÚMERO DE CARGO permanece fijo.
-- El NOMBRE DEL SOLICITANTE sí puede corregirse.
-- ============================================================

alter table public.cargos
  add column if not exists updated_at timestamptz not null default now();

alter table public.cargos
  add column if not exists updated_by uuid null default auth.uid();

create or replace function public.guardar_cargo_con_solicitante_editable(
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
    -- El NÚMERO DE CARGO NO CAMBIA.
    -- El nombre sí puede ser corregido por el usuario antes de imprimir.
    update public.cargos
    set solicitante = trim(p_solicitante),
        observacion = coalesce(nullif(trim(p_observacion),''), observacion),
        updated_at = now(),
        updated_by = auth.uid()
    where id = v_cargo.id;

    v_id := v_cargo.id;
  else
    insert into public.cargos(
      numero, solicitante, fecha, observacion, updated_at, updated_by
    )
    values(
      trim(p_numero),
      trim(p_solicitante),
      coalesce(p_fecha,current_date),
      nullif(trim(p_observacion),''),
      now(),
      auth.uid()
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

grant update on public.cargos to authenticated;
grant execute on function public.guardar_cargo_con_solicitante_editable(text,text,date,text,uuid[]) to authenticated;

drop policy if exists "cargos_update_authenticated" on public.cargos;
create policy "cargos_update_authenticated"
on public.cargos for update
to authenticated
using (true)
with check (true);
