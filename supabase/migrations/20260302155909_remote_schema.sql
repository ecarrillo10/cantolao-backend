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

set check_function_bodies = off;

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
               FROM generate_series(((date_trunc('day'::text, p.fecha_inicio))::date)::timestamp with time zone, ((date_trunc('day'::text, COALESCE(p.fecha_fin, p.fecha_inicio)))::date)::timestamp with time zone, '1 day'::interval) gs(gs)
              ORDER BY ((gs.gs)::date))
        END AS fechas
   FROM public.cb_precios_combustible p;


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
DROP VIEW IF EXISTS public.vw_detalle_conductor;
create or replace view "public"."vw_detalle_conductor" as  SELECT c.id_conductor,
    COALESCE(c.nombre, 'Sin información'::character varying(100)) AS nombre,
    COALESCE(c.dni, 'Sin información'::character varying(100)) AS dni,
    COALESCE(c.telefono, 'Sin información'::character varying(100)) AS telefono,
    COALESCE(c.licencia, 'Sin información'::character varying(100)) AS licencia,
    c.fecha_vencimiento_licencia,
    COALESCE(c.email, 'Sin información'::character varying(100)) AS email,
    COALESCE(c.categoria, 'Sin información'::character varying(100)) AS categoria,
    COALESCE(cl.razon_social, 'Sin información'::character varying(100)) AS razon_social,
    COALESCE(cl.ruc, 'Sin información'::character varying(100)) AS ruc,
    COALESCE(c.estado, false) AS estado
   FROM (public.ms_conductores c
     JOIN public.ms_clientes cl ON ((cl.id_cliente = c.id_cliente)));



