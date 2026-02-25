create sequence "public"."app_version_rules_id_seq";

revoke delete on table "public"."ms_proveedores" from "anon";

revoke insert on table "public"."ms_proveedores" from "anon";

revoke references on table "public"."ms_proveedores" from "anon";

revoke select on table "public"."ms_proveedores" from "anon";

revoke trigger on table "public"."ms_proveedores" from "anon";

revoke truncate on table "public"."ms_proveedores" from "anon";

revoke update on table "public"."ms_proveedores" from "anon";

revoke delete on table "public"."ms_proveedores" from "authenticated";

revoke insert on table "public"."ms_proveedores" from "authenticated";

revoke references on table "public"."ms_proveedores" from "authenticated";

revoke select on table "public"."ms_proveedores" from "authenticated";

revoke trigger on table "public"."ms_proveedores" from "authenticated";

revoke truncate on table "public"."ms_proveedores" from "authenticated";

revoke update on table "public"."ms_proveedores" from "authenticated";

revoke delete on table "public"."ms_proveedores" from "service_role";

revoke insert on table "public"."ms_proveedores" from "service_role";

revoke references on table "public"."ms_proveedores" from "service_role";

revoke select on table "public"."ms_proveedores" from "service_role";

revoke trigger on table "public"."ms_proveedores" from "service_role";

revoke truncate on table "public"."ms_proveedores" from "service_role";

revoke update on table "public"."ms_proveedores" from "service_role";

revoke delete on table "public"."spatial_ref_sys" from "anon";

revoke insert on table "public"."spatial_ref_sys" from "anon";

revoke references on table "public"."spatial_ref_sys" from "anon";

revoke select on table "public"."spatial_ref_sys" from "anon";

revoke trigger on table "public"."spatial_ref_sys" from "anon";

revoke truncate on table "public"."spatial_ref_sys" from "anon";

revoke update on table "public"."spatial_ref_sys" from "anon";

revoke delete on table "public"."spatial_ref_sys" from "authenticated";

revoke insert on table "public"."spatial_ref_sys" from "authenticated";

revoke references on table "public"."spatial_ref_sys" from "authenticated";

revoke select on table "public"."spatial_ref_sys" from "authenticated";

revoke trigger on table "public"."spatial_ref_sys" from "authenticated";

revoke truncate on table "public"."spatial_ref_sys" from "authenticated";

revoke update on table "public"."spatial_ref_sys" from "authenticated";

revoke delete on table "public"."spatial_ref_sys" from "postgres";

revoke insert on table "public"."spatial_ref_sys" from "postgres";

revoke references on table "public"."spatial_ref_sys" from "postgres";

revoke select on table "public"."spatial_ref_sys" from "postgres";

revoke trigger on table "public"."spatial_ref_sys" from "postgres";

revoke truncate on table "public"."spatial_ref_sys" from "postgres";

revoke update on table "public"."spatial_ref_sys" from "postgres";

revoke delete on table "public"."spatial_ref_sys" from "service_role";

revoke insert on table "public"."spatial_ref_sys" from "service_role";

revoke references on table "public"."spatial_ref_sys" from "service_role";

revoke select on table "public"."spatial_ref_sys" from "service_role";

revoke trigger on table "public"."spatial_ref_sys" from "service_role";

revoke truncate on table "public"."spatial_ref_sys" from "service_role";

revoke update on table "public"."spatial_ref_sys" from "service_role";

alter table "public"."rl_proveedor_estacion" drop constraint "rl_proveedor_estacion_id_proveedor_fkey";

drop function if exists "public"."fn_registrar_abastecimiento"(p_id_cliente integer, p_id_estacion integer, p_id_vehiculo integer, p_id_conductor integer, p_id_combustible integer, p_galones numeric, p_kilometraje integer, p_qrgenerado uuid, p_id_operador integer, p_id_estado integer);

alter table "public"."ms_proveedores" drop constraint "ms_proveedores_pkey";

drop index if exists "public"."ms_proveedores_pkey";

drop table "public"."ms_proveedores";


  create table "public"."app_version_rules" (
    "id" bigint not null default nextval('public.app_version_rules_id_seq'::regclass),
    "platform" text not null,
    "min_build" integer not null,
    "latest_build" integer not null,
    "force_update" boolean not null default true,
    "store_url" text not null,
    "message" text not null default 'Hay una actualización disponible.'::text,
    "enabled" boolean not null default true,
    "created_at" timestamp with time zone default now(),
    "updated_at" timestamp with time zone default now()
      );


alter table "public"."app_version_rules" enable row level security;

alter table "public"."ms_combustibles" enable row level security;

alter table "public"."ms_conductores" enable row level security;

alter table "public"."ms_contactos_cliente" enable row level security;

alter table "public"."ms_estaciones" enable row level security;

alter table "public"."ms_estados" enable row level security;

alter table "public"."ms_estados_facturacion" enable row level security;

alter table "public"."ms_feriados" enable row level security;

alter table "public"."ms_operadores_estacion" enable row level security;

alter table "public"."ms_periodos_facturacion" enable row level security;

alter table "public"."ms_roles" enable row level security;

alter table "public"."ms_tipos_estacion" enable row level security;

alter table "public"."ms_tipos_linea_credito" enable row level security;

alter table "public"."ms_usuarios" enable row level security;

alter table "public"."ms_vehiculos" enable row level security;

alter table "public"."ms_zonas" enable row level security;

alter table "public"."pagos" enable row level security;

alter table "public"."rl_proveedor_estacion" enable row level security;

alter table "public"."rl_vehiculo_combustible" enable row level security;

alter sequence "public"."app_version_rules_id_seq" owned by "public"."app_version_rules"."id";

drop sequence if exists "public"."ms_proveedores_id_proveedor_seq";

CREATE UNIQUE INDEX app_version_rules_pkey ON public.app_version_rules USING btree (id);

alter table "public"."app_version_rules" add constraint "app_version_rules_pkey" PRIMARY KEY using index "app_version_rules_pkey";

alter table "public"."app_version_rules" add constraint "app_version_rules_platform_check" CHECK ((platform = ANY (ARRAY['android'::text, 'ios'::text]))) not valid;

alter table "public"."app_version_rules" validate constraint "app_version_rules_platform_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.fn_registrar_abastecimiento(p_id_cliente integer, p_id_estacion integer, p_id_vehiculo integer, p_id_conductor integer, p_id_combustible integer, p_galones numeric, p_kilometraje integer, p_qrgenerado uuid, p_id_operador integer DEFAULT NULL::integer, p_id_estado integer DEFAULT 1)
 RETURNS TABLE(ok boolean, id_abastecimiento integer, precio numeric, total numeric, nro_transaccion text, codigo text, mensaje text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$

DECLARE
  v_precio numeric;
  v_total  numeric;
  v_id     integer;
  v_id_precio bigint;
  v_nro_transaccion text;
BEGIN
  -- ===== Validaciones mínimas =====
  IF p_qrgenerado IS NULL THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'QR_REQUIRED'::text,
      'El QR es obligatorio.'::text;
    RETURN;
  END IF;

  IF p_galones IS NULL OR p_galones <= 0 THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'INVALID_GALONES'::text,
      'Galones debe ser mayor a 0.'::text;
    RETURN;
  END IF;

  -- Vehículo pertenece al cliente y activo
  IF NOT EXISTS (
    SELECT 1
    FROM public.ms_vehiculos v
    WHERE v.id_vehiculo = p_id_vehiculo
      AND v.id_cliente  = p_id_cliente
      AND COALESCE(v.estado, true) = true
  ) THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'VEHICULO_INVALIDO'::text,
      'El vehículo no existe, no pertenece al cliente o está inactivo.'::text;
    RETURN;
  END IF;

  -- Conductor pertenece al cliente y activo
  IF NOT EXISTS (
    SELECT 1
    FROM public.ms_conductores c
    WHERE c.id_conductor = p_id_conductor
      AND c.id_cliente   = p_id_cliente
      AND COALESCE(c.estado, true) = true
  ) THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'CONDUCTOR_INVALIDO'::text,
      'El conductor no existe, no pertenece al cliente o está inactivo.'::text;
    RETURN;
  END IF;

  -- Conductor asignado al vehículo (vigente)
  IF NOT EXISTS (
    SELECT 1
    FROM public.cb_asignaciones_conductor a
    WHERE a.id_vehiculo  = p_id_vehiculo
      AND a.id_conductor = p_id_conductor
      AND COALESCE(a.estado, true) = true
      AND (a.fecha_inicio IS NULL OR a.fecha_inicio <= CURRENT_DATE)
      AND (a.fecha_fin    IS NULL OR a.fecha_fin    >= CURRENT_DATE)
  ) THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'ASIGNACION_INVALIDA'::text,
      'El conductor no está asignado al vehículo.'::text;
    RETURN;
  END IF;

  -- Vehículo permite ese combustible
  IF NOT EXISTS (
    SELECT 1
    FROM public.rl_vehiculo_combustible r
    WHERE r.id_vehiculo = p_id_vehiculo
      AND r.id_combustible = p_id_combustible
  ) THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'COMBUSTIBLE_NO_PERMITIDO'::text,
      'El vehículo no tiene asignado ese combustible.'::text;
    RETURN;
  END IF;

  -- Operador (si viene) debe estar activo y asignado a la estación
  IF p_id_operador IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.ms_operadores_estacion o
      WHERE o.id_operador = p_id_operador
        AND o.id_estacion = p_id_estacion
        AND COALESCE(o.activo, true) = true
    ) THEN
      RETURN QUERY SELECT
        false::boolean,
        NULL::integer,
        NULL::numeric,
        NULL::numeric,
        NULL::text,
        'OPERADOR_INVALIDO'::text,
        'Operador inválido o no pertenece a la estación.'::text;
      RETURN;
    END IF;
  END IF;

  -- Precio vigente
  SELECT pc.precio, pc.id_precio
    INTO v_precio, v_id_precio
  FROM public.cb_precios_combustible pc
  WHERE pc.id_cliente = p_id_cliente
    AND pc.id_estacion = p_id_estacion
    AND pc.id_combustible = p_id_combustible
    AND COALESCE(pc.estado, true) = true
    AND (pc.fecha_inicio IS NULL OR pc.fecha_inicio <= now())
    AND (pc.fecha_fin    IS NULL OR pc.fecha_fin    >= now())
  ORDER BY pc.fecha_inicio DESC NULLS LAST
  LIMIT 1;

  IF v_precio IS NULL THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'PRICE_NOT_FOUND'::text,
      'No hay precio vigente para ese cliente/estación/combustible.'::text;
    RETURN;
  END IF;

  v_total := p_galones * v_precio;

  -- INSERT abastecimiento
  INSERT INTO public.cb_abastecimientos (
    id_estacion,
    id_cliente,
    id_vehiculo,
    id_conductor,
    id_combustible,
    galones,
    total,
    kilometraje,
    qrgenerado,
    id_operador,
    id_estado,
    id_precio
  )
  VALUES (
    p_id_estacion,
    p_id_cliente,
    p_id_vehiculo,
    p_id_conductor,
    p_id_combustible,
    p_galones,
    v_total,
    p_kilometraje,
    p_qrgenerado,
    p_id_operador,
    p_id_estado,
    v_id_precio
  )
  RETURNING public.cb_abastecimientos.id_abastecimiento INTO v_id;

  -- Generar nro_transaccion (ARREGLADO con alias + retorno)
  UPDATE public.cb_abastecimientos a
  SET nro_transaccion = v_id::text || to_char(a.fecha_hora, 'DDMMYYYY')
  WHERE a.id_abastecimiento = v_id
  RETURNING a.nro_transaccion INTO v_nro_transaccion;

  -- AUDITORIA (igual que tu lógica)
  INSERT INTO public.auditoria (
    usuario,
    tabla_afectada,
    accion,
    registro_id,
    data_before,
    data_after
  )
  SELECT
    o.id_usuario,
    'cb_abastecimientos',
    'INSERT_ABASTECIMIENTO',
    v_id::text,
    NULL,
    to_jsonb(a)
  FROM public.cb_abastecimientos a
  JOIN public.ms_operadores_estacion o
    ON o.id_operador = p_id_operador
  WHERE a.id_abastecimiento = v_id
    AND o.id_usuario IS NOT NULL;

  -- UPDATE QR
  UPDATE public.cb_qr_generados
  SET id_estado = 4
  WHERE id_qr = p_qrgenerado
    AND id_estado = 2;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR inválido: no existe o ya no está AUTORIZADO';
  END IF;

  RETURN QUERY SELECT
    true::boolean,
    v_id::integer,
    v_precio::numeric,
    v_total::numeric,
    v_nro_transaccion::text,
    'OK'::text,
    'Abastecimiento registrado.'::text;
  RETURN;

EXCEPTION
  WHEN unique_violation THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'QR_DUPLICADO'::text,
      'Ese QR ya fue usado en un abastecimiento.'::text;
    RETURN;

  WHEN others THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      NULL::text,
      'DB_ERROR'::text,
      SQLERRM::text;
    RETURN;
END;
$function$
;

create or replace view "public"."vw_admin_abastecimientos" as  SELECT a.id_abastecimiento,
    a.fecha_hora,
    a.galones,
    a.total,
    a.kilometraje,
    ef.id_estado_facturacion,
    ef.nombre AS estado_facturacion,
    c.id_cliente,
    c.razon_social,
    c.ruc,
    v.id_vehiculo,
    v.placa,
    v.marca,
    v.modelo,
    v.tipo,
    d.id_conductor,
    d.id_usuario,
    d.nombre AS conductor,
    d.dni,
    d.licencia,
    comb.nombre AS combustible,
    e.id_estacion,
    e.nombre AS estacion,
    z.nombre AS zona,
    te.nombre AS tipo_estacion,
    a.id_operador,
    qr.id_qr,
    qr.fecha_generada AS qr_fecha,
    qr.id_estado AS qr_estado_id,
    estqr.nombre AS qr_estado,
    a.nro_transaccion
   FROM ((((((((((public.cb_abastecimientos a
     LEFT JOIN public.ms_estados_facturacion ef ON ((ef.id_estado_facturacion = a.id_estado)))
     LEFT JOIN public.ms_clientes c ON ((c.id_cliente = a.id_cliente)))
     LEFT JOIN public.ms_vehiculos v ON ((v.id_vehiculo = a.id_vehiculo)))
     LEFT JOIN public.ms_conductores d ON ((d.id_conductor = a.id_conductor)))
     LEFT JOIN public.ms_combustibles comb ON ((comb.id_combustible = a.id_combustible)))
     LEFT JOIN public.ms_estaciones e ON ((e.id_estacion = a.id_estacion)))
     LEFT JOIN public.ms_zonas z ON ((z.id_zona = e.id_zona)))
     LEFT JOIN public.ms_tipos_estacion te ON ((te.id_tipo_estacion = e.id_tipo_estacion)))
     LEFT JOIN public.cb_qr_generados qr ON ((qr.id_qr = a.qrgenerado)))
     LEFT JOIN public.ms_estados estqr ON ((estqr.id_estado = qr.id_estado)));


grant delete on table "public"."app_version_rules" to "anon";

grant insert on table "public"."app_version_rules" to "anon";

grant references on table "public"."app_version_rules" to "anon";

grant select on table "public"."app_version_rules" to "anon";

grant trigger on table "public"."app_version_rules" to "anon";

grant truncate on table "public"."app_version_rules" to "anon";

grant update on table "public"."app_version_rules" to "anon";

grant delete on table "public"."app_version_rules" to "authenticated";

grant insert on table "public"."app_version_rules" to "authenticated";

grant references on table "public"."app_version_rules" to "authenticated";

grant select on table "public"."app_version_rules" to "authenticated";

grant trigger on table "public"."app_version_rules" to "authenticated";

grant truncate on table "public"."app_version_rules" to "authenticated";

grant update on table "public"."app_version_rules" to "authenticated";

grant delete on table "public"."app_version_rules" to "service_role";

grant insert on table "public"."app_version_rules" to "service_role";

grant references on table "public"."app_version_rules" to "service_role";

grant select on table "public"."app_version_rules" to "service_role";

grant trigger on table "public"."app_version_rules" to "service_role";

grant truncate on table "public"."app_version_rules" to "service_role";

grant update on table "public"."app_version_rules" to "service_role";


  create policy "public_read_app_version_rules"
  on "public"."app_version_rules"
  as permissive
  for select
  to public
using ((enabled = true));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_combustibles"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_combustibles"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_combustibles"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_conductores"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_conductores"
  as permissive
  for select
  to authenticated, anon
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_conductores"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_contactos_cliente"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_contactos_cliente"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_contactos_cliente"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_estaciones"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_estaciones"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_estaciones"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_estados"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_estados"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_estados"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_estados_facturacion"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_estados_facturacion"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_estados_facturacion"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_feriados"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_feriados"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_feriados"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_operadores_estacion"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_operadores_estacion"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_operadores_estacion"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_periodos_facturacion"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_periodos_facturacion"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_periodos_facturacion"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_roles"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_roles"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_roles"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_tipos_estacion"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_tipos_estacion"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_tipos_estacion"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_tipos_linea_credito"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_tipos_linea_credito"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_tipos_linea_credito"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_usuarios"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_usuarios"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_usuarios"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_vehiculos"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_vehiculos"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_vehiculos"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."ms_zonas"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."ms_zonas"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."ms_zonas"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."pagos"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."pagos"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."pagos"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."rl_proveedor_estacion"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."rl_proveedor_estacion"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."rl_proveedor_estacion"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Insert"
  on "public"."rl_vehiculo_combustible"
  as permissive
  for insert
  to authenticated
with check ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Select"
  on "public"."rl_vehiculo_combustible"
  as permissive
  for select
  to authenticated
using ((auth.role() = 'authenticated'::text));



  create policy "Usuarios autenticados_Update"
  on "public"."rl_vehiculo_combustible"
  as permissive
  for update
  to authenticated
using ((auth.role() = 'authenticated'::text));



