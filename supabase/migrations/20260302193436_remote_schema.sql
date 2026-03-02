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

drop view if exists "public"."vw_reporteglobal_abastecimientos";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.get_max_galones_por_vehiculo(p_id_vehiculo integer, p_id_combustible integer, p_id_cliente integer, p_id_estacion integer)
 RETURNS TABLE(saldo_disponible numeric, precio numeric, galones_maximos numeric)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_saldo  numeric;
  v_precio numeric;
BEGIN
  -- 1) Obtener saldo desde tu función (ajusta el schema si no es public)
  v_saldo := COALESCE(public.fn_saldo_disponible_vehiculo(p_id_vehiculo), 0);

  -- 2) Obtener último precio vigente por estación/cliente/combustible
  SELECT pc.precio
    INTO v_precio
  FROM cb_precios_combustible pc
  WHERE pc.id_combustible = p_id_combustible
    AND pc.id_cliente     = p_id_cliente
    AND pc.id_estacion    = p_id_estacion
    AND pc.estado         = true
  ORDER BY pc.fecha_inicio DESC
  LIMIT 1;

  IF v_precio IS NULL OR v_precio <= 0 THEN
    RAISE EXCEPTION 'No existe precio vigente válido para combustible %, cliente %, estación %',
      p_id_combustible, p_id_cliente, p_id_estacion;
  END IF;

  -- 3) Retornar (si saldo <= 0, galones_maximos queda en 0)
  RETURN QUERY
  SELECT
    v_saldo AS saldo_disponible,
    v_precio AS precio,
    CASE
      WHEN v_saldo <= 0 THEN 0
      ELSE ROUND(v_saldo / v_precio, 3)
    END AS galones_maximos;

END;
$function$
;

create or replace view "public"."vw_cb_precios_combustible_fechas" as  SELECT id_precio,
    id_cliente,
    id_estacion,
    id_combustible,
    precio,
    fecha_inicio,
    fecha_fin,
    estado,
        CASE
            WHEN (fecha_inicio IS NULL) THEN '{}'::date[]
            WHEN ((fecha_fin IS NOT NULL) AND (fecha_fin < fecha_inicio)) THEN '{}'::date[]
            ELSE ARRAY( SELECT (gs.gs)::date AS gs
               FROM generate_series(((date_trunc('day'::text, p.fecha_inicio))::date)::timestamp with time zone, ((date_trunc('day'::text, COALESCE(p.fecha_fin, (CURRENT_DATE)::timestamp with time zone)))::date)::timestamp with time zone, '1 day'::interval) gs(gs)
              ORDER BY ((gs.gs)::date))
        END AS fechas
   FROM public.cb_precios_combustible p;


create or replace view "public"."vw_reporteglobal_abastecimientos" as  SELECT date_trunc('day'::text, a.fecha_hora) AS fecha,
    a.fecha_hora,
    a.id_abastecimiento,
    cl.id_cliente,
    cl.razon_social AS cliente,
    e.id_estacion,
    e.nombre AS estacion,
    z.id_zona,
    z.nombre AS zona,
    cb.id_combustible,
    cb.nombre AS combustible,
    a.galones,
    round(
        CASE
            WHEN (a.galones > (0)::numeric) THEN (a.total / a.galones)
            ELSE (0)::numeric
        END, 4) AS precio_gal,
    a.total AS monto
   FROM ((((public.cb_abastecimientos a
     JOIN public.ms_clientes cl ON ((cl.id_cliente = a.id_cliente)))
     JOIN public.ms_estaciones e ON ((e.id_estacion = a.id_estacion)))
     LEFT JOIN public.ms_zonas z ON ((z.id_zona = e.id_zona)))
     JOIN public.ms_combustibles cb ON ((cb.id_combustible = a.id_combustible)))
  ORDER BY a.fecha_hora DESC, cl.razon_social, e.nombre;



