drop extension if exists "pg_net";

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


  create policy "Uploads jhnwbj_0"
  on "storage"."objects"
  as permissive
  for select
  to public
using ((bucket_id = 'Documentos'::text));



  create policy "Uploads1 jhnwbj_0"
  on "storage"."objects"
  as permissive
  for insert
  to public
with check ((bucket_id = 'Documentos'::text));



  create policy "Uploads2 jhnwbj_0"
  on "storage"."objects"
  as permissive
  for update
  to public
using ((bucket_id = 'Documentos'::text));



  create policy "Uploads3 jhnwbj_0"
  on "storage"."objects"
  as permissive
  for delete
  to public
using ((bucket_id = 'Documentos'::text));



