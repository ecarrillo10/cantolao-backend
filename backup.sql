


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";








ALTER SCHEMA "public" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "postgis" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."fn_ajuste_masivo_precios_excel"("p_filas" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  fila jsonb;

  v_id_zona int;
  v_id_combustible int;
  v_variacion numeric;

  v_precio record;
  v_nuevo_precio numeric;

  v_inicio_proceso timestamptz := now();

  v_total_insertados int := 0;
  v_filas_omitidas int := 0;
  v_errores jsonb := '[]'::jsonb;

  -- parseo seguro
  s_id_zona text;
  s_id_combustible text;
  s_variacion text;

  -- textos usuario
  t_zona text;
  t_combustible text;

  -- control por fila
  v_estaciones_total int;
  v_estaciones_error int;
BEGIN
  FOR fila IN
    SELECT * FROM jsonb_array_elements(p_filas)
  LOOP
    /* =========================
       Lectura segura del Excel
    ========================= */
    s_id_zona        := NULLIF(btrim(fila->>'id_zona'), '');
    s_id_combustible := NULLIF(btrim(fila->>'id_combustible'), '');
    s_variacion      := NULLIF(btrim(fila->>'variacion'), '');

    BEGIN
      v_id_zona := s_id_zona::int;
      v_id_combustible := s_id_combustible::int;
      v_variacion := s_variacion::numeric;
    EXCEPTION WHEN OTHERS THEN
      v_filas_omitidas := v_filas_omitidas + 1;
      v_errores := v_errores || jsonb_build_array(
        jsonb_build_object(
          'mensaje',
          'Hay valores inválidos en el archivo. Revise la zona, el combustible y la variación.'
        )
      );
      CONTINUE;
    END;

    /* =========================
       Textos legibles (fallback)
    ========================= */
    t_zona := 'Zona ' || v_id_zona;
    t_combustible := 'Combustible ' || v_id_combustible;

    BEGIN
      SELECT nombre INTO t_zona
      FROM ms_zonas
      WHERE id_zona = v_id_zona;
    EXCEPTION WHEN OTHERS THEN
      -- fallback
    END;

    BEGIN
      SELECT nombre INTO t_combustible
      FROM ms_combustibles
      WHERE id_combustible = v_id_combustible;
    EXCEPTION WHEN OTHERS THEN
      -- fallback
    END;

    /* =========================
       Variación inválida
    ========================= */
    IF v_variacion IS NULL THEN
      v_filas_omitidas := v_filas_omitidas + 1;
      v_errores := v_errores || jsonb_build_array(
        jsonb_build_object(
          'mensaje',
          t_zona || ' – ' || t_combustible ||
          ': El valor ingresado no es válido. Revise la variación.'
        )
      );
      CONTINUE;
    END IF;

    /* =========================
       Inicializar control fila
    ========================= */
    v_estaciones_total := 0;
    v_estaciones_error := 0;

    /* =========================
       Procesar precios vigentes
    ========================= */
    FOR v_precio IN
      SELECT p.*
      FROM cb_precios_combustible p
      JOIN ms_estaciones e ON e.id_estacion = p.id_estacion
      WHERE e.id_zona = v_id_zona
        AND p.id_combustible = v_id_combustible
        AND p.estado = true
        AND p.fecha_fin IS NULL
        AND p.fecha_inicio <= v_inicio_proceso
    LOOP
      v_estaciones_total := v_estaciones_total + 1;
      v_nuevo_precio := v_precio.precio + v_variacion;

      IF v_nuevo_precio <= 0 THEN
        v_estaciones_error := v_estaciones_error + 1;
        CONTINUE;
      END IF;

      /* cerrar precio anterior */
      UPDATE cb_precios_combustible
      SET estado = false,
          fecha_fin = v_inicio_proceso
      WHERE id_precio = v_precio.id_precio;

      /* insertar nuevo precio */
      INSERT INTO cb_precios_combustible (
        id_cliente,
        id_estacion,
        id_combustible,
        precio,
        fecha_inicio,
        estado
      ) VALUES (
        v_precio.id_cliente,
        v_precio.id_estacion,
        v_precio.id_combustible,
        v_nuevo_precio,
        v_inicio_proceso,
        true
      );

      v_total_insertados := v_total_insertados + 1;
    END LOOP;

    /* =========================
       Mensaje único por fila
    ========================= */
    IF v_estaciones_total > 0
       AND v_estaciones_error = v_estaciones_total THEN
      v_filas_omitidas := v_filas_omitidas + 1;
      v_errores := v_errores || jsonb_build_array(
        jsonb_build_object(
          'mensaje',
          t_zona || ' – ' || t_combustible ||
          ': El ajuste no se pudo aplicar a ninguna estación.'
        )
      );
    END IF;

  END LOOP;

  RETURN jsonb_build_object(
    'status', 'OK',
    'precios_aplicados', v_total_insertados,
    'filas_omitidas', v_filas_omitidas,
    'mensajes', v_errores
  );
END;
$$;


ALTER FUNCTION "public"."fn_ajuste_masivo_precios_excel"("p_filas" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_calc_cierre"("p_periodo_id" integer, "p_hoy" "date") RETURNS TABLE("periodo_id" integer, "base_end" "date", "fin_consumo" "date", "ejecucion" "date", "inicio_consumo" "date")
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_anchor date := p_hoy - 1;     -- “ayer” como referencia para encontrar el cierre que podría ejecutar HOY
  v_candidates date[];
  v_base date;
  v_fin date;
  v_exec date;

  v_month_end date;
  v_prev_month_end date;
  v_q15 date;

  i int;
BEGIN
  -- candidatos comunes
  v_month_end := (date_trunc('month', v_anchor) + interval '1 month - 1 day')::date;
  v_prev_month_end := (date_trunc('month', v_anchor) - interval '1 day')::date;
  v_q15 := make_date(extract(year from v_anchor)::int, extract(month from v_anchor)::int, 15);

  -- construir candidatos según periodo_id
  IF p_periodo_id = 1 THEN
    -- SEMANAL:
    -- 1) domingo de la semana del anchor
    -- 2) fin de mes del mes del anchor
    -- 3) fin de mes del mes anterior (por si se extendió a inicio de mes)
    v_candidates := ARRAY[
      (v_anchor - extract(dow from v_anchor)::int),  -- domingo <= anchor
      v_month_end,
      v_prev_month_end
    ];

  ELSIF p_periodo_id = 2 THEN
    -- QUINCENAL: 15 o fin de mes (y fin de mes anterior por extensión)
    v_candidates := ARRAY[
      v_q15,
      v_month_end,
      v_prev_month_end
    ];

  ELSIF p_periodo_id = 3 THEN
    -- MENSUAL: fin de mes (y fin de mes anterior por extensión)
    v_candidates := ARRAY[
      v_month_end,
      v_prev_month_end
    ];

  ELSE
    RETURN; -- periodo no soportado
  END IF;

  -- evaluar cada candidato: si su ejecucion = hoy, entonces ese es el cierre
  FOR i IN array_lower(v_candidates, 1)..array_upper(v_candidates, 1)
  LOOP
    v_base := v_candidates[i];

    -- Evitar candidatos absurdos (por ejemplo 15 futuro si anchor aún no llega)
    IF p_periodo_id = 2 AND v_base = v_q15 AND v_anchor < v_q15 THEN
      CONTINUE;
    END IF;

    -- regla universal de ejecución:
    -- ejec = base + 1; si cae no hábil, se corre al siguiente hábil
    -- e INCLUYE esos días en consumo (fin_consumo se extiende)
    v_fin := v_base;
    v_exec := v_base + 1;

    WHILE public.fn_es_no_habil(v_exec) LOOP
      v_fin := v_exec;       -- incluir el no hábil en consumo
      v_exec := v_exec + 1;  -- mover ejecución
    END LOOP;

    -- ¿Este candidato ejecuta HOY?
    IF v_exec = p_hoy THEN
      periodo_id := p_periodo_id;
      base_end := v_base;
      fin_consumo := v_fin;
      ejecucion := v_exec;

      -- inicio según tipo (USANDO IDs, no nombres)
      IF p_periodo_id = 3 THEN
        -- mensual: inicio = primer día del mes del base_end (aunque fin_consumo se haya extendido)
        inicio_consumo := date_trunc('month', v_base)::date;

      ELSIF p_periodo_id = 2 THEN
        -- quincenal calendario:
        IF extract(day from v_base) = 15 THEN
          inicio_consumo := make_date(extract(year from v_base)::int, extract(month from v_base)::int, 1);
        ELSE
          inicio_consumo := make_date(extract(year from v_base)::int, extract(month from v_base)::int, 16);
        END IF;

      ELSE
        -- semanal:
        -- regla robusta:
        -- - normalmente: semana que termina en domingo => inicio lunes de esa semana
        -- - si base_end es lunes (casos extendidos por feriado/fin de mes lunes), incluye semana anterior completa + lunes => inicio = lunes anterior (base_end - 7)
        IF extract(dow from v_base) = 1 THEN
          inicio_consumo := v_base - 7;
        ELSE
          inicio_consumo := date_trunc('week', v_base)::date; -- lunes de la semana del base_end
        END IF;
      END IF;

      RETURN NEXT;
      RETURN;
    END IF;
  END LOOP;

  RETURN;
END;
$$;


ALTER FUNCTION "public"."fn_calc_cierre"("p_periodo_id" integer, "p_hoy" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_cierre_facturacion"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_hoy date := (now() AT TIME ZONE 'America/Lima')::date;

  v_id_pendiente int := 1;
  v_id_facturado int := 2;

  r_linea record;
  r_calc record;
  v_registros int;
  v_ids text;

BEGIN
  FOR r_linea IN
    SELECT id_linea, id_cliente, id_periodo_facturacion
    FROM public.cb_lineas
    WHERE estado = true
      AND id_periodo_facturacion IS NOT NULL
  LOOP

    SELECT *
    INTO r_calc
    FROM public.fn_calc_cierre(r_linea.id_periodo_facturacion, v_hoy)
    LIMIT 1;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    -- obtener IDs antes del update
    SELECT string_agg(id_abastecimiento::text, ',')
    INTO v_ids
    FROM public.cb_abastecimientos
    WHERE id_cliente = r_linea.id_cliente
      AND id_estado = v_id_pendiente
      AND fecha_hora::date BETWEEN r_calc.inicio_consumo AND r_calc.fin_consumo;

    -- ✅ UPDATE con fecha_facturacion
    UPDATE public.cb_abastecimientos a
       SET id_estado = v_id_facturado,
           fecha_facturacion = r_calc.ejecucion
     WHERE a.id_cliente = r_linea.id_cliente
       AND a.id_estado = v_id_pendiente
       AND a.fecha_hora::date BETWEEN r_calc.inicio_consumo AND r_calc.fin_consumo;

    GET DIAGNOSTICS v_registros = ROW_COUNT;

    IF v_registros > 0 THEN
      INSERT INTO public.auditoria (
        tabla_afectada,
        accion,
        fecha,
        registro_id,
        data_after
      )
      VALUES (
        'cb_abastecimientos',
        'CIERRE_FACTURACION',
        now(),
        v_ids,
        jsonb_build_object(
          'id_linea', r_linea.id_linea,
          'id_cliente', r_linea.id_cliente,
          'periodo_id', r_linea.id_periodo_facturacion,
          'base_end', r_calc.base_end,
          'inicio_consumo', r_calc.inicio_consumo,
          'fin_consumo', r_calc.fin_consumo,
          'ejecucion', r_calc.ejecucion,
          'fecha_facturacion_set', r_calc.ejecucion,
          'registros_facturados', v_registros
        )
      );
    END IF;

  END LOOP;
END;
$$;


ALTER FUNCTION "public"."fn_cierre_facturacion"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_cierre_facturacion_test"("p_hoy" "date") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_id_pendiente int := 1;
  v_id_facturado int := 2;

  r_linea record;
  r_calc record;
  v_registros int;
  v_total int := 0;
  v_ids int[];
BEGIN
  FOR r_linea IN
    SELECT l.id_linea, l.id_cliente, l.id_periodo_facturacion
    FROM public.cb_lineas l
    WHERE l.estado = true
      AND l.id_periodo_facturacion IS NOT NULL
  LOOP

    SELECT *
    INTO r_calc
    FROM public.fn_calc_cierre(r_linea.id_periodo_facturacion, p_hoy)
    LIMIT 1;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    -- 🔹 capturar ids a afectar (NUEVO)
    SELECT array_agg(a.id_abastecimiento)
    INTO v_ids
    FROM public.cb_abastecimientos a
    WHERE a.id_cliente = r_linea.id_cliente
      AND a.id_estado = v_id_pendiente
      AND a.fecha_hora::date
          BETWEEN r_calc.inicio_consumo AND r_calc.fin_consumo;

    IF v_ids IS NULL THEN
      CONTINUE;
    END IF;

    UPDATE public.cb_abastecimientos
    SET id_estado = v_id_facturado
    WHERE id_abastecimiento = ANY(v_ids);

    GET DIAGNOSTICS v_registros = ROW_COUNT;
    v_total := v_total + v_registros;

    IF v_registros > 0 THEN
      INSERT INTO public.auditoria (
        usuario,
        tabla_afectada,
        accion,
        registro_id,
        fecha,
        data_after
      )
      VALUES (
        null,
        'cb_abastecimientos',
        'CIERRE_FACTURACION_TEST',
        array_to_string(v_ids, ','),
        now(),
        jsonb_build_object(
          'modo','TEST',
          'fecha_simulada', p_hoy,
          'ids', v_ids,
          'id_linea', r_linea.id_linea,
          'id_cliente', r_linea.id_cliente,
          'periodo_id', r_linea.id_periodo_facturacion,
          'base_end', r_calc.base_end,
          'inicio_consumo', r_calc.inicio_consumo,
          'fin_consumo', r_calc.fin_consumo,
          'ejecucion', r_calc.ejecucion,
          'registros_facturados', v_registros
        )
      );
    END IF;

  END LOOP;

  RETURN jsonb_build_object(
    'hoy_simulado', p_hoy,
    'registros_actualizados', v_total
  );
END;
$$;


ALTER FUNCTION "public"."fn_cierre_facturacion_test"("p_hoy" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_es_no_habil"("p_fecha" "date") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- domingo(0) o sábado(6)
  IF extract(dow from p_fecha) IN (0,6) THEN
    RETURN true;
  END IF;

  -- feriado en tabla
  IF EXISTS (SELECT 1 FROM public.ms_feriados f WHERE f.fecha = p_fecha) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$$;


ALTER FUNCTION "public"."fn_es_no_habil"("p_fecha" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_kpi_global"("p_cliente" integer DEFAULT NULL::integer) RETURNS TABLE("total_galones" numeric, "monto_total" numeric, "total_consumos" bigint, "precio_promedio" numeric)
    LANGUAGE "sql"
    AS $$
  select
    sum(a.galones),
    sum(a.total),
    count(a.id_abastecimiento),
    round(
      case
        when sum(a.galones) > 0
          then sum(a.total) / sum(a.galones)
        else 0
      end,
      2
    )::numeric(12,2)
  from cb_abastecimientos a
  where
    p_cliente is null
    or a.id_cliente = p_cliente;
$$;


ALTER FUNCTION "public"."fn_kpi_global"("p_cliente" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_registrar_abastecimiento"("p_id_cliente" integer, "p_id_estacion" integer, "p_id_vehiculo" integer, "p_id_conductor" integer, "p_id_combustible" integer, "p_galones" numeric, "p_kilometraje" integer, "p_qrgenerado" "uuid", "p_id_operador" integer DEFAULT NULL::integer, "p_id_estado" integer DEFAULT 1) RETURNS TABLE("ok" boolean, "id_abastecimiento" integer, "precio" numeric, "total" numeric, "codigo" "text", "mensaje" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$

DECLARE
  v_precio numeric;
  v_total  numeric;
  v_id     integer;
  v_id_precio bigint; -- ✅ agregado
BEGIN
  -- ===== Validaciones mínimas =====
  IF p_qrgenerado IS NULL THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
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
        'OPERADOR_INVALIDO'::text,
        'Operador inválido o no pertenece a la estación.'::text;
      RETURN;
    END IF;
  END IF;

  -- Precio vigente  ✅ SOLO ampliado
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
      'PRICE_NOT_FOUND'::text,
      'No hay precio vigente para ese cliente/estación/combustible.'::text;
    RETURN;
  END IF;

  v_total := p_galones * v_precio;

  -- ===== INSERT abastecimiento =====  ✅ SOLO agregado id_precio
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

  -- ✅✅✅ NUEVO: generar nro_transaccion = id_abastecimiento + DDMMYYYY (día mes año)
  UPDATE public.cb_abastecimientos
  SET nro_transaccion = v_id::text || to_char(fecha_hora, 'DDMMYYYY')
  WHERE id_abastecimiento = v_id;

  -- ===== AUDITORIA =====
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

  -- ===== UPDATE QR =====
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
      'QR_DUPLICADO'::text,
      'Ese QR ya fue usado en un abastecimiento.'::text;
    RETURN;

  WHEN others THEN
    RETURN QUERY SELECT
      false::boolean,
      NULL::integer,
      NULL::numeric,
      NULL::numeric,
      'DB_ERROR'::text,
      SQLERRM::text;
    RETURN;
END;
$$;


ALTER FUNCTION "public"."fn_registrar_abastecimiento"("p_id_cliente" integer, "p_id_estacion" integer, "p_id_vehiculo" integer, "p_id_conductor" integer, "p_id_combustible" integer, "p_galones" numeric, "p_kilometraje" integer, "p_qrgenerado" "uuid", "p_id_operador" integer, "p_id_estado" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_saldo_disponible_vehiculo"("p_id_vehiculo" integer) RETURNS numeric
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_id_cliente INTEGER;
  v_tope_vehiculo NUMERIC;
  v_id_centro INTEGER;

  v_tope_linea NUMERIC;
  v_tope_centro NUMERIC;

  v_total_centros NUMERIC := 0;
  v_total_vehiculos_sin_centro_con_monto NUMERIC := 0;
  v_consumo_sin_monto NUMERIC := 0;

  v_consumo_vehiculo NUMERIC := 0;
  v_consumo_centro NUMERIC := 0;

  v_saldo_linea NUMERIC := 0;
  v_saldo_resultante NUMERIC := 0;
BEGIN
  -- 1️⃣ OBTENER VEHÍCULO
  SELECT id_cliente, monto_asignado, id_centro_costo
  INTO v_id_cliente, v_tope_vehiculo, v_id_centro
  FROM ms_vehiculos
  WHERE id_vehiculo = p_id_vehiculo;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Vehículo no existe';
  END IF;

  -- 2️⃣ OBTENER LÍNEA ACTIVA
  SELECT monto_asignado
  INTO v_tope_linea
  FROM cb_lineas
  WHERE id_cliente = v_id_cliente
    AND estado = true
  ORDER BY id_linea DESC
  LIMIT 1;

  IF v_tope_linea IS NULL THEN
    RAISE EXCEPTION 'Cliente sin línea activa';
  END IF;

  -- 3️⃣ SUMA DE CENTROS ACTIVOS (opcional: AND monto_asignado IS NOT NULL)
  SELECT COALESCE(SUM(monto_asignado), 0)
  INTO v_total_centros
  FROM ms_centro_costo
  WHERE id_cliente = v_id_cliente
    AND estado = true;

  -- 4️⃣ VEHÍCULOS SIN CENTRO CON MONTO
  SELECT COALESCE(SUM(monto_asignado), 0)
  INTO v_total_vehiculos_sin_centro_con_monto
  FROM ms_vehiculos
  WHERE id_cliente = v_id_cliente
    AND id_centro_costo IS NULL
    AND monto_asignado IS NOT NULL;

  -- 5️⃣ CONSUMO VEHÍCULOS SIN MONTO
  SELECT COALESCE(SUM(a.total), 0)
  INTO v_consumo_sin_monto
  FROM cb_abastecimientos a
  JOIN ms_vehiculos v ON v.id_vehiculo = a.id_vehiculo
  WHERE v.id_cliente = v_id_cliente
    AND v.id_centro_costo IS NULL
    AND v.monto_asignado IS NULL
    AND a.id_estado IN (1,2);

  -- 6️⃣ SALDO REAL GLOBAL DE LÍNEA
  v_saldo_linea :=
    v_tope_linea
    - v_total_centros
    - v_total_vehiculos_sin_centro_con_monto
    - v_consumo_sin_monto;

  -- 7️⃣ CONSUMO DEL VEHÍCULO ACTUAL
  SELECT COALESCE(SUM(total), 0)
  INTO v_consumo_vehiculo
  FROM cb_abastecimientos
  WHERE id_vehiculo = p_id_vehiculo
    AND id_estado IN (1,2);

  -- 8️⃣ SI TIENE TOPE PROPIO
  IF v_tope_vehiculo IS NOT NULL THEN
    v_saldo_resultante := LEAST(
      v_saldo_linea,
      v_tope_vehiculo - v_consumo_vehiculo
    );
    RETURN GREATEST(v_saldo_resultante, 0);
  END IF;

  -- 9️⃣ SI TIENE CENTRO DE COSTO
  IF v_id_centro IS NOT NULL THEN
    SELECT monto_asignado
    INTO v_tope_centro
    FROM ms_centro_costo
    WHERE id_centro_costo = v_id_centro;

    IF v_tope_centro IS NULL THEN
      RAISE EXCEPTION 'Centro de costos sin tope configurado';
    END IF;

    SELECT COALESCE(SUM(a.total), 0)
    INTO v_consumo_centro
    FROM cb_abastecimientos a
    JOIN ms_vehiculos v ON v.id_vehiculo = a.id_vehiculo
    WHERE v.id_centro_costo = v_id_centro
      AND a.id_estado IN (1,2);

    v_saldo_resultante := LEAST(
      v_saldo_linea,
      v_tope_centro - v_consumo_centro
    );

    RETURN GREATEST(v_saldo_resultante, 0);
  END IF;

  -- 🔟 SOLO LÍNEA
  RETURN GREATEST(v_saldo_linea, 0);
END;
$$;


ALTER FUNCTION "public"."fn_saldo_disponible_vehiculo"("p_id_vehiculo" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_set_default_permisos"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.permisos IS NULL THEN
    NEW.permisos := '{
      "Estación": {"read": false, "create": false, "delete": false, "update": false},
      "Facturación": {"read": false, "create": false},
      "Gestión de Precios": {"read": false, "create": false, "delete": false, "update": false},
      "Líneas de Crédito": {"read": false, "create": false, "delete": false, "update": false},
      "Usuarios y permisos": {"read": false, "create": false, "delete": false, "update": false},
      "Clientes Corporativos": {"read": false, "create": false, "delete": false, "update": false},
      "Reportes y Analíticas": {"read": false},
      "Conciliar Abastecimientos": {"read": false, "create": false, "delete": false, "update": false},
      "Asignación Vehículos - Conductor": {"read": false}
    }'::jsonb;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_set_default_permisos"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_max_galones_por_vehiculo"("p_id_vehiculo" integer, "p_id_combustible" integer, "p_id_cliente" integer, "p_id_estacion" integer) RETURNS TABLE("saldo_disponible" numeric, "precio" numeric, "galones_maximos" numeric)
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."get_max_galones_por_vehiculo"("p_id_vehiculo" integer, "p_id_combustible" integer, "p_id_cliente" integer, "p_id_estacion" integer) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."auditoria" (
    "id_evento" bigint NOT NULL,
    "usuario" "uuid",
    "fecha" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tabla_afectada" "text" NOT NULL,
    "accion" "text" NOT NULL,
    "registro_id" "text",
    "data_before" "jsonb",
    "data_after" "jsonb"
);


ALTER TABLE "public"."auditoria" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."auditoria_id_evento_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."auditoria_id_evento_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."auditoria_id_evento_seq" OWNED BY "public"."auditoria"."id_evento";



CREATE TABLE IF NOT EXISTS "public"."cb_abastecimientos" (
    "id_abastecimiento" integer NOT NULL,
    "id_estacion" integer,
    "id_cliente" integer,
    "id_vehiculo" integer,
    "id_conductor" integer,
    "id_combustible" integer,
    "galones" numeric(10,3),
    "total" numeric(15,2),
    "kilometraje" integer,
    "fecha_hora" timestamp with time zone DEFAULT "now"(),
    "id_operador" integer,
    "qrgenerado" "uuid" NOT NULL,
    "id_estado" integer NOT NULL,
    "fecha_facturacion" "date",
    "fecha_pago" "date",
    "id_precio" bigint,
    "nro_transaccion" "text"
);


ALTER TABLE "public"."cb_abastecimientos" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."cb_abastecimientos_id_abastecimiento_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."cb_abastecimientos_id_abastecimiento_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."cb_abastecimientos_id_abastecimiento_seq" OWNED BY "public"."cb_abastecimientos"."id_abastecimiento";



CREATE TABLE IF NOT EXISTS "public"."cb_asignaciones_conductor" (
    "id_asignacion" integer NOT NULL,
    "id_vehiculo" integer,
    "id_conductor" integer,
    "fecha_inicio" "date",
    "fecha_fin" "date",
    "estado" boolean DEFAULT true
);


ALTER TABLE "public"."cb_asignaciones_conductor" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."cb_asignaciones_conductor_id_asignacion_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."cb_asignaciones_conductor_id_asignacion_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."cb_asignaciones_conductor_id_asignacion_seq" OWNED BY "public"."cb_asignaciones_conductor"."id_asignacion";



CREATE TABLE IF NOT EXISTS "public"."cb_facturacion" (
    "id_factura" integer NOT NULL,
    "id_cliente" integer,
    "monto_facturado" numeric(15,2),
    "fecha_facturacion" timestamp with time zone,
    "estado" boolean
);


ALTER TABLE "public"."cb_facturacion" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."cb_facturacion_id_factura_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."cb_facturacion_id_factura_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."cb_facturacion_id_factura_seq" OWNED BY "public"."cb_facturacion"."id_factura";



CREATE TABLE IF NOT EXISTS "public"."cb_lineas" (
    "id_linea" integer NOT NULL,
    "id_cliente" integer NOT NULL,
    "monto_asignado" numeric(15,2),
    "estado" boolean DEFAULT true,
    "id_tipo_linea" integer NOT NULL,
    "id_periodo_facturacion" integer,
    "fecha_creacion" "date" DEFAULT CURRENT_DATE,
    "plazo_de_pago" smallint
);


ALTER TABLE "public"."cb_lineas" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."cb_lineas_id_linea_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."cb_lineas_id_linea_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."cb_lineas_id_linea_seq" OWNED BY "public"."cb_lineas"."id_linea";



CREATE TABLE IF NOT EXISTS "public"."cb_precios_combustible" (
    "id_cliente" integer,
    "id_estacion" integer,
    "id_combustible" integer,
    "precio" numeric(10,3),
    "fecha_inicio" timestamp with time zone,
    "fecha_fin" timestamp with time zone,
    "estado" boolean DEFAULT true,
    "id_precio" bigint NOT NULL
);


ALTER TABLE "public"."cb_precios_combustible" OWNER TO "postgres";


ALTER TABLE "public"."cb_precios_combustible" ALTER COLUMN "id_precio" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."cb_precios_combustible_id_precio_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."cb_qr_generados" (
    "id_qr" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "id_conductor" integer,
    "id_vehiculo" integer,
    "id_combustible" integer,
    "fecha_generada" timestamp with time zone DEFAULT "now"(),
    "id_estado" integer,
    "fecha_expiracion" timestamp with time zone,
    "id_estacion" integer
);


ALTER TABLE "public"."cb_qr_generados" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ms_centro_costo" (
    "id_centro_costo" integer NOT NULL,
    "nombre" character varying NOT NULL,
    "id_cliente" integer,
    "estado" boolean DEFAULT true,
    "monto_asignado" numeric
);


ALTER TABLE "public"."ms_centro_costo" OWNER TO "postgres";


ALTER TABLE "public"."ms_centro_costo" ALTER COLUMN "id_centro_costo" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."ms_ceentro_costo_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."ms_clientes" (
    "id_cliente" integer NOT NULL,
    "ruc" character varying(20),
    "razon_social" character varying(255),
    "direccion" "text",
    "telefono" character varying(20),
    "estado" boolean
);


ALTER TABLE "public"."ms_clientes" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ms_clientes_id_cliente_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_clientes_id_cliente_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_clientes_id_cliente_seq" OWNED BY "public"."ms_clientes"."id_cliente";



CREATE TABLE IF NOT EXISTS "public"."ms_combustibles" (
    "id_combustible" integer NOT NULL,
    "nombre" character varying(100)
);


ALTER TABLE "public"."ms_combustibles" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ms_combustibles_id_combustible_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_combustibles_id_combustible_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_combustibles_id_combustible_seq" OWNED BY "public"."ms_combustibles"."id_combustible";



CREATE TABLE IF NOT EXISTS "public"."ms_conductores" (
    "id_conductor" integer NOT NULL,
    "id_usuario" "uuid",
    "nombre" character varying(100),
    "dni" character varying(20),
    "telefono" character varying(20),
    "licencia" character varying(50),
    "fecha_vencimiento_licencia" "date",
    "estado" boolean DEFAULT true,
    "id_cliente" integer NOT NULL,
    "email" character varying,
    "categoria" character varying
);


ALTER TABLE "public"."ms_conductores" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ms_conductores_id_conductor_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_conductores_id_conductor_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_conductores_id_conductor_seq" OWNED BY "public"."ms_conductores"."id_conductor";



CREATE TABLE IF NOT EXISTS "public"."ms_contactos_cliente" (
    "id_contacto" "uuid" NOT NULL,
    "id_cliente" integer,
    "nombre" character varying(100),
    "email" character varying(150),
    "telefono" character varying(20),
    "contactoPrincipal" boolean,
    "estado" boolean DEFAULT true
);


ALTER TABLE "public"."ms_contactos_cliente" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ms_estaciones" (
    "id_estacion" integer NOT NULL,
    "nombre" character varying(150),
    "ubicacion" "text",
    "latitud" numeric(10,8),
    "longitud" numeric(11,8),
    "estado" boolean DEFAULT true,
    "id_zona" integer,
    "id_tipo_estacion" integer
);


ALTER TABLE "public"."ms_estaciones" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ms_estaciones_id_estacion_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_estaciones_id_estacion_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_estaciones_id_estacion_seq" OWNED BY "public"."ms_estaciones"."id_estacion";



CREATE TABLE IF NOT EXISTS "public"."ms_estados" (
    "id_estado" integer NOT NULL,
    "nombre" character varying(50) NOT NULL
);


ALTER TABLE "public"."ms_estados" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ms_estados_facturacion" (
    "id_estado_facturacion" integer NOT NULL,
    "nombre" "text" NOT NULL
);


ALTER TABLE "public"."ms_estados_facturacion" OWNER TO "postgres";


ALTER TABLE "public"."ms_estados_facturacion" ALTER COLUMN "id_estado_facturacion" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."ms_estados_facturacion_id_estado_facturacion_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."ms_estados_id_estado_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_estados_id_estado_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_estados_id_estado_seq" OWNED BY "public"."ms_estados"."id_estado";



CREATE TABLE IF NOT EXISTS "public"."ms_feriados" (
    "fecha" "date" NOT NULL,
    "descripcion" "text"
);


ALTER TABLE "public"."ms_feriados" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ms_operadores_estacion" (
    "id_operador" integer NOT NULL,
    "id_usuario" "uuid",
    "id_estacion" integer,
    "activo" boolean DEFAULT true,
    "turno" character varying(50),
    "fecha_asignacion" timestamp with time zone DEFAULT "now"(),
    "correo" character varying
);


ALTER TABLE "public"."ms_operadores_estacion" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ms_operadores_estacion_id_operador_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_operadores_estacion_id_operador_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_operadores_estacion_id_operador_seq" OWNED BY "public"."ms_operadores_estacion"."id_operador";



CREATE TABLE IF NOT EXISTS "public"."ms_periodos_facturacion" (
    "id_periodo" integer NOT NULL,
    "nombre" character varying NOT NULL
);


ALTER TABLE "public"."ms_periodos_facturacion" OWNER TO "postgres";


ALTER TABLE "public"."ms_periodos_facturacion" ALTER COLUMN "id_periodo" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."ms_periodos_facturacion_id_periodo_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."ms_proveedores" (
    "id_proveedor" integer NOT NULL,
    "nombre" character varying(150)
);


ALTER TABLE "public"."ms_proveedores" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ms_proveedores_id_proveedor_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_proveedores_id_proveedor_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_proveedores_id_proveedor_seq" OWNED BY "public"."ms_proveedores"."id_proveedor";



CREATE TABLE IF NOT EXISTS "public"."ms_roles" (
    "id_rol" integer NOT NULL,
    "nombre" character varying NOT NULL,
    "descripcion" "text",
    "permisos" "jsonb" DEFAULT '{"Estación": {"read": false, "create": false, "delete": false, "update": false}, "Facturación": {"read": false, "create": false, "delete": false, "update": false}, "Gestión de Precios": {"read": false, "create": false, "delete": false, "update": false}, "Líneas de Crédito": {"read": false, "create": false, "delete": false, "update": false}, "Usuarios y permisos": {"read": false, "create": false, "delete": false, "update": false}, "Clientes Corporativos": {"read": false, "create": false, "delete": false, "update": false}, "Reportes y Analíticas": {"read": false}, "Conciliar Abastecimientos": {"read": false, "create": false, "delete": false, "update": false}, "Asignación Vehículos - Conductor": {"read": false}}'::"jsonb",
    "estado" boolean DEFAULT true,
    "fecha_creacion" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ms_roles" OWNER TO "postgres";


ALTER TABLE "public"."ms_roles" ALTER COLUMN "id_rol" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."ms_roles_id_rol_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."ms_tipos_estacion" (
    "id_tipo_estacion" integer NOT NULL,
    "nombre" character varying NOT NULL
);


ALTER TABLE "public"."ms_tipos_estacion" OWNER TO "postgres";


ALTER TABLE "public"."ms_tipos_estacion" ALTER COLUMN "id_tipo_estacion" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."ms_tipos_estacion_id_tipo_estacion_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."ms_tipos_linea_credito" (
    "id_tipo_linea" integer NOT NULL,
    "nombre" character varying NOT NULL
);


ALTER TABLE "public"."ms_tipos_linea_credito" OWNER TO "postgres";


ALTER TABLE "public"."ms_tipos_linea_credito" ALTER COLUMN "id_tipo_linea" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."ms_tipos_linea_credito_id_tipo_linea_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."ms_usuarios" (
    "id_usuario" "uuid" NOT NULL,
    "nombre" character varying(100),
    "apellido" character varying(100),
    "email" character varying(150),
    "estado" boolean,
    "dni" character varying(20),
    "id_rol" integer
);


ALTER TABLE "public"."ms_usuarios" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ms_vehiculos" (
    "id_vehiculo" integer NOT NULL,
    "placa" character varying(20),
    "tipo" character varying(50),
    "marca" character varying(150),
    "anio" integer,
    "estado" boolean DEFAULT true,
    "id_cliente" integer,
    "modelo" character varying,
    "id_centro_costo" integer,
    "monto_asignado" numeric
);


ALTER TABLE "public"."ms_vehiculos" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ms_vehiculos_id_vehiculo_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_vehiculos_id_vehiculo_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_vehiculos_id_vehiculo_seq" OWNED BY "public"."ms_vehiculos"."id_vehiculo";



CREATE TABLE IF NOT EXISTS "public"."ms_zonas" (
    "id_zona" integer NOT NULL,
    "nombre" character varying(150)
);


ALTER TABLE "public"."ms_zonas" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."ms_zonas_id_zona_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."ms_zonas_id_zona_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."ms_zonas_id_zona_seq" OWNED BY "public"."ms_zonas"."id_zona";



CREATE TABLE IF NOT EXISTS "public"."pagos" (
    "id_pago" integer NOT NULL,
    "id_linea" integer,
    "numero_factura" character varying(100),
    "monto_pagado" numeric(15,2),
    "fecha_pago" timestamp with time zone
);


ALTER TABLE "public"."pagos" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."pagos_id_pago_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pagos_id_pago_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pagos_id_pago_seq" OWNED BY "public"."pagos"."id_pago";



CREATE TABLE IF NOT EXISTS "public"."rl_proveedor_estacion" (
    "id_proveedor" integer NOT NULL,
    "id_estacion" integer NOT NULL
);


ALTER TABLE "public"."rl_proveedor_estacion" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rl_vehiculo_combustible" (
    "id_vehiculo" integer NOT NULL,
    "id_combustible" integer NOT NULL
);


ALTER TABLE "public"."rl_vehiculo_combustible" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_abastecimientos_diarios_30d" WITH ("security_invoker"='on') AS
 WITH "dias" AS (
         SELECT ("generate_series"((CURRENT_DATE - '29 days'::interval), (CURRENT_DATE)::timestamp without time zone, '1 day'::interval))::"date" AS "fecha"
        )
 SELECT "d"."fecha",
    COALESCE("sum"("a"."total"), (0)::numeric) AS "total_ventas",
    COALESCE("sum"("a"."galones"), (0)::numeric) AS "total_galones",
    COALESCE("count"("a".*), (0)::bigint) AS "total_tickets"
   FROM ("dias" "d"
     LEFT JOIN "public"."cb_abastecimientos" "a" ON (("date"("a"."fecha_hora") = "d"."fecha")))
  GROUP BY "d"."fecha"
  ORDER BY "d"."fecha";


ALTER VIEW "public"."vw_abastecimientos_diarios_30d" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_abastecimientos_diarios_15d_arrays" WITH ("security_invoker"='on') AS
 SELECT "array_agg"((EXTRACT(day FROM "fecha"))::integer ORDER BY "fecha") AS "dias",
    "array_agg"("total_ventas" ORDER BY "fecha") AS "ventas",
    "array_agg"("total_galones" ORDER BY "fecha") AS "galones",
    "array_agg"("total_tickets" ORDER BY "fecha") AS "tickets"
   FROM "public"."vw_abastecimientos_diarios_30d"
  WHERE ("fecha" >= (CURRENT_DATE - '14 days'::interval));


ALTER VIEW "public"."vw_abastecimientos_diarios_15d_arrays" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_abastecimientos_no_facturados" WITH ("security_invoker"='on') AS
 SELECT "a"."id_abastecimiento",
    "a"."id_cliente",
    "c"."razon_social",
    ("a"."fecha_hora")::"date" AS "fecha_consumo",
    "a"."fecha_hora",
    "a"."id_estacion",
    "e"."nombre" AS "estacion",
    "a"."id_vehiculo",
    "v"."placa",
    "a"."id_conductor",
    "d"."nombre" AS "conductor",
    "a"."id_combustible",
    "co"."nombre" AS "combustible",
    "pc"."precio" AS "precio_combustible",
    "a"."galones",
    "a"."total",
    "a"."kilometraje",
    "a"."id_estado"
   FROM (((((("public"."cb_abastecimientos" "a"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "a"."id_cliente")))
     LEFT JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
     LEFT JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "a"."id_vehiculo")))
     LEFT JOIN "public"."ms_conductores" "d" ON (("d"."id_conductor" = "a"."id_conductor")))
     LEFT JOIN "public"."ms_combustibles" "co" ON (("co"."id_combustible" = "a"."id_combustible")))
     LEFT JOIN "public"."cb_precios_combustible" "pc" ON (("pc"."id_precio" = "a"."id_precio")))
  WHERE (("a"."id_estado" = 1) AND ("a"."fecha_facturacion" IS NULL));


ALTER VIEW "public"."vw_abastecimientos_no_facturados" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_abastecimientos_ultimos_movimientos" WITH ("security_invoker"='on') AS
 SELECT "a"."id_abastecimiento",
    "a"."fecha_hora",
    "c"."id_cliente",
    "c"."razon_social" AS "cliente",
    "co"."id_conductor",
    "co"."nombre" AS "conductor",
    "v"."id_vehiculo",
    "v"."placa" AS "vehiculo",
    "e"."id_estacion",
    "e"."nombre" AS "estacion",
    "a"."galones",
    "a"."total"
   FROM (((("public"."cb_abastecimientos" "a"
     LEFT JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "a"."id_cliente")))
     LEFT JOIN "public"."ms_conductores" "co" ON (("co"."id_conductor" = "a"."id_conductor")))
     LEFT JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "a"."id_vehiculo")))
     LEFT JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
  ORDER BY "a"."fecha_hora" DESC;


ALTER VIEW "public"."vw_abastecimientos_ultimos_movimientos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_abastecimientos" WITH ("security_invoker"='on') AS
 SELECT "a"."id_abastecimiento",
    "a"."fecha_hora",
    "a"."galones",
    "a"."total",
    "a"."kilometraje",
    "ef"."id_estado_facturacion",
    "ef"."nombre" AS "estado_facturacion",
    "c"."id_cliente",
    "c"."razon_social",
    "c"."ruc",
    "v"."id_vehiculo",
    "v"."placa",
    "v"."marca",
    "v"."modelo",
    "v"."tipo",
    "d"."id_conductor",
    "d"."id_usuario",
    "d"."nombre" AS "conductor",
    "d"."dni",
    "d"."licencia",
    "comb"."nombre" AS "combustible",
    "e"."id_estacion",
    "e"."nombre" AS "estacion",
    "z"."nombre" AS "zona",
    "te"."nombre" AS "tipo_estacion",
    "a"."id_operador",
    "qr"."id_qr",
    "qr"."fecha_generada" AS "qr_fecha",
    "qr"."id_estado" AS "qr_estado_id",
    "estqr"."nombre" AS "qr_estado"
   FROM (((((((((("public"."cb_abastecimientos" "a"
     LEFT JOIN "public"."ms_estados_facturacion" "ef" ON (("ef"."id_estado_facturacion" = "a"."id_estado")))
     LEFT JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "a"."id_cliente")))
     LEFT JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "a"."id_vehiculo")))
     LEFT JOIN "public"."ms_conductores" "d" ON (("d"."id_conductor" = "a"."id_conductor")))
     LEFT JOIN "public"."ms_combustibles" "comb" ON (("comb"."id_combustible" = "a"."id_combustible")))
     LEFT JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
     LEFT JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
     LEFT JOIN "public"."ms_tipos_estacion" "te" ON (("te"."id_tipo_estacion" = "e"."id_tipo_estacion")))
     LEFT JOIN "public"."cb_qr_generados" "qr" ON (("qr"."id_qr" = "a"."qrgenerado")))
     LEFT JOIN "public"."ms_estados" "estqr" ON (("estqr"."id_estado" = "qr"."id_estado")));


ALTER VIEW "public"."vw_admin_abastecimientos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_admin_abastecimientos_kpi_mensual" AS
 WITH "base" AS (
         SELECT "vw_admin_abastecimientos"."id_abastecimiento",
            "vw_admin_abastecimientos"."fecha_hora",
            "vw_admin_abastecimientos"."galones"
           FROM "public"."vw_admin_abastecimientos"
        ), "agg" AS (
         SELECT ("date_trunc"('month'::"text", "base"."fecha_hora"))::"date" AS "mes",
            "count"(*) AS "despachos_registrados_mensual",
            COALESCE("sum"("base"."galones"), (0)::numeric) AS "total_galones_mensual",
            "max"("base"."fecha_hora") AS "ultimo_registro_mes"
           FROM "base"
          GROUP BY ("date_trunc"('month'::"text", "base"."fecha_hora"))
        ), "last_id" AS (
         SELECT DISTINCT ON (("date_trunc"('month'::"text", "base"."fecha_hora"))) ("date_trunc"('month'::"text", "base"."fecha_hora"))::"date" AS "mes",
            "base"."id_abastecimiento" AS "ultimo_id_abastecimiento_mes"
           FROM "base"
          ORDER BY ("date_trunc"('month'::"text", "base"."fecha_hora")), "base"."fecha_hora" DESC, "base"."id_abastecimiento" DESC
        )
 SELECT "a"."mes",
    (EXTRACT(year FROM "a"."mes"))::integer AS "anio",
    (EXTRACT(month FROM "a"."mes"))::integer AS "mes_num",
    "a"."despachos_registrados_mensual",
    "a"."total_galones_mensual",
    "a"."ultimo_registro_mes",
    "l"."ultimo_id_abastecimiento_mes"
   FROM ("agg" "a"
     LEFT JOIN "last_id" "l" ON (("l"."mes" = "a"."mes")))
  ORDER BY "a"."mes" DESC;


ALTER VIEW "public"."vw_admin_abastecimientos_kpi_mensual" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_asignaciones_conductor" WITH ("security_invoker"='on') AS
 SELECT "ac"."id_asignacion",
    "v"."id_vehiculo",
    "v"."placa",
    "cli"."id_cliente",
    "cli"."razon_social" AS "cliente",
    "c"."id_conductor",
    "c"."nombre" AS "conductor",
    "c"."dni",
    "c"."licencia",
    "ac"."fecha_inicio",
    "ac"."fecha_fin",
        CASE
            WHEN ("ac"."estado" = false) THEN 'Finalizada'::"text"
            WHEN ("ac"."fecha_inicio" > CURRENT_DATE) THEN 'Programada'::"text"
            ELSE 'Activa'::"text"
        END AS "estado_texto",
    "ac"."estado"
   FROM ((("public"."cb_asignaciones_conductor" "ac"
     JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "ac"."id_vehiculo")))
     JOIN "public"."ms_clientes" "cli" ON (("cli"."id_cliente" = "v"."id_cliente")))
     JOIN "public"."ms_conductores" "c" ON (("c"."id_conductor" = "ac"."id_conductor")));


ALTER VIEW "public"."vw_asignaciones_conductor" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_centro_costo_estado" WITH ("security_invoker"='on') AS
 SELECT "id_centro_costo",
    "nombre",
    "id_cliente",
    "estado",
    "monto_asignado",
    ((("nombre")::"text" || ' | Monto asignado : S/ '::"text") ||
        CASE
            WHEN (COALESCE("monto_asignado", (0)::numeric) = (0)::numeric) THEN '0'::"text"
            WHEN (COALESCE("monto_asignado", (0)::numeric) = "floor"(COALESCE("monto_asignado", (0)::numeric))) THEN "to_char"(COALESCE("monto_asignado", (0)::numeric), 'FM999G999G999'::"text")
            ELSE "to_char"(COALESCE("monto_asignado", (0)::numeric), 'FM999G999G999D00'::"text")
        END) AS "nombre_monto"
   FROM "public"."ms_centro_costo" "cc"
  WHERE ("estado" = true);


ALTER VIEW "public"."vw_centro_costo_estado" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_cliente_contacto_principal" WITH ("security_invoker"='on') AS
 SELECT "c"."id_cliente",
    "c"."ruc",
    "c"."razon_social",
    "c"."direccion",
    "c"."telefono",
    "c"."estado",
    "cc"."id_contacto" AS "id_usuario_contacto",
    "cc"."nombre" AS "nombre_contacto_principal",
    "count"("v"."id_vehiculo") AS "cant_vehiculos"
   FROM (("public"."ms_clientes" "c"
     LEFT JOIN "public"."ms_contactos_cliente" "cc" ON ((("cc"."id_cliente" = "c"."id_cliente") AND ("cc"."contactoPrincipal" = true))))
     LEFT JOIN "public"."ms_vehiculos" "v" ON (("v"."id_cliente" = "c"."id_cliente")))
  GROUP BY "c"."id_cliente", "c"."ruc", "c"."razon_social", "c"."direccion", "c"."telefono", "c"."estado", "cc"."id_contacto", "cc"."nombre";


ALTER VIEW "public"."vw_cliente_contacto_principal" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_clientes_con_cantidad_vehiculos" WITH ("security_invoker"='on') AS
 SELECT "c"."id_cliente",
    "c"."ruc",
    "c"."razon_social",
    "c"."direccion",
    "c"."telefono",
    "c"."estado",
    "count"("v"."id_vehiculo") AS "cantidad_vehiculos"
   FROM ("public"."ms_clientes" "c"
     LEFT JOIN "public"."ms_vehiculos" "v" ON (("v"."id_cliente" = "c"."id_cliente")))
  GROUP BY "c"."id_cliente", "c"."ruc", "c"."razon_social", "c"."direccion", "c"."telefono", "c"."estado";


ALTER VIEW "public"."vw_clientes_con_cantidad_vehiculos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_clientes_zonas_estaciones" WITH ("security_invoker"='on') AS
 SELECT DISTINCT "c"."id_cliente",
    "z"."id_zona",
    "z"."nombre" AS "zona",
    "e"."id_estacion",
    "e"."nombre" AS "estacion",
    "e"."estado" AS "estacion_activa"
   FROM ((("public"."cb_precios_combustible" "p"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "p"."id_cliente")))
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "p"."id_estacion")))
     JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
  WHERE (("p"."estado" = true) AND ("z"."id_zona" <> 12))
UNION ALL
 SELECT DISTINCT "c"."id_cliente",
    "z"."id_zona",
    ((("z"."nombre")::"text" || ' - '::"text") || ("e"."nombre")::"text") AS "zona",
    "e"."id_estacion",
    "e"."nombre" AS "estacion",
    "e"."estado" AS "estacion_activa"
   FROM ((("public"."cb_precios_combustible" "p"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "p"."id_cliente")))
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "p"."id_estacion")))
     JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
  WHERE (("p"."estado" = true) AND ("z"."id_zona" = 12));


ALTER VIEW "public"."vw_clientes_zonas_estaciones" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_combustibles_cliente" WITH ("security_invoker"='on') AS
 SELECT "pc"."id_cliente",
    "pc"."id_combustible",
    "c"."nombre" AS "nombre_combustible",
    "pc"."precio"
   FROM (("public"."cb_precios_combustible" "pc"
     JOIN "public"."ms_estaciones" "e" ON ((("e"."id_estacion" = "pc"."id_estacion") AND ("e"."estado" = true))))
     JOIN "public"."ms_combustibles" "c" ON (("c"."id_combustible" = "pc"."id_combustible")))
  WHERE ("pc"."estado" = true)
  GROUP BY "pc"."id_cliente", "pc"."id_combustible", "c"."nombre", "pc"."precio";


ALTER VIEW "public"."vw_combustibles_cliente" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_combustibles_dropdown" WITH ("security_invoker"='on') AS
 SELECT "id_combustible",
    "nombre"
   FROM ( SELECT 0 AS "id_combustible",
            'TODOS'::character varying AS "nombre"
        UNION ALL
         SELECT "c"."id_combustible",
            "c"."nombre"
           FROM "public"."ms_combustibles" "c") "t"
  ORDER BY
        CASE
            WHEN ("id_combustible" = 0) THEN 0
            ELSE 1
        END, "nombre";


ALTER VIEW "public"."vw_combustibles_dropdown" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_conductores_sin_vehiculo" WITH ("security_invoker"='on') AS
 SELECT "id_cliente",
    ("count"(*))::integer AS "conductores_sin_vehiculo"
   FROM "public"."ms_conductores" "c"
  WHERE (("estado" = true) AND (NOT (EXISTS ( SELECT 1
           FROM "public"."cb_asignaciones_conductor" "a"
          WHERE (("a"."id_conductor" = "c"."id_conductor") AND ("a"."estado" = true) AND (("a"."fecha_fin" IS NULL) OR ("a"."fecha_fin" >= CURRENT_DATE)))))))
  GROUP BY "id_cliente";


ALTER VIEW "public"."vw_conductores_sin_vehiculo" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_consumo_galones_por_combustible_mes_actual_arrays" WITH ("security_invoker"='on') AS
 WITH "base" AS (
         SELECT "a"."id_cliente",
            "c"."razon_social",
            "a"."id_combustible",
            "cb"."nombre" AS "combustible_nombre",
            "sum"(COALESCE("a"."galones", (0)::numeric)) AS "galones_total",
            "sum"(COALESCE("a"."total", (0)::numeric)) AS "monto_total"
           FROM (("public"."cb_abastecimientos" "a"
             JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "a"."id_cliente")))
             JOIN "public"."ms_combustibles" "cb" ON (("cb"."id_combustible" = "a"."id_combustible")))
          WHERE (("a"."fecha_hora" >= "date_trunc"('month'::"text", ("now"() AT TIME ZONE 'America/Lima'::"text"))) AND ("a"."fecha_hora" < ("date_trunc"('month'::"text", ("now"() AT TIME ZONE 'America/Lima'::"text")) + '1 mon'::interval)) AND ("a"."id_cliente" IS NOT NULL) AND ("a"."id_combustible" IS NOT NULL))
          GROUP BY "a"."id_cliente", "c"."razon_social", "a"."id_combustible", "cb"."nombre"
        )
 SELECT "id_cliente",
    "razon_social",
    "array_agg"("id_combustible" ORDER BY "galones_total" DESC) AS "id_combustibles",
    "array_agg"("combustible_nombre" ORDER BY "galones_total" DESC) AS "combustibles",
    "array_agg"("galones_total" ORDER BY "galones_total" DESC) AS "galones",
    "array_agg"("monto_total" ORDER BY "galones_total" DESC) AS "montos"
   FROM "base"
  GROUP BY "id_cliente", "razon_social";


ALTER VIEW "public"."vw_consumo_galones_por_combustible_mes_actual_arrays" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_consumo_galones_por_estacion_mes_actual_arrays" WITH ("security_invoker"='on') AS
 WITH "base" AS (
         SELECT "a"."id_cliente",
            "c"."razon_social",
            "a"."id_estacion",
            "e"."nombre" AS "estacion_nombre",
            "sum"(COALESCE("a"."galones", (0)::numeric)) AS "galones_total",
            "sum"(COALESCE("a"."total", (0)::numeric)) AS "monto_total"
           FROM (("public"."cb_abastecimientos" "a"
             JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "a"."id_cliente")))
             JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
          WHERE (("a"."fecha_hora" >= "date_trunc"('month'::"text", ("now"() AT TIME ZONE 'America/Lima'::"text"))) AND ("a"."fecha_hora" < ("date_trunc"('month'::"text", ("now"() AT TIME ZONE 'America/Lima'::"text")) + '1 mon'::interval)) AND ("a"."id_cliente" IS NOT NULL) AND ("a"."id_estacion" IS NOT NULL))
          GROUP BY "a"."id_cliente", "c"."razon_social", "a"."id_estacion", "e"."nombre"
        )
 SELECT "id_cliente",
    "razon_social",
    "array_agg"("id_estacion" ORDER BY "galones_total" DESC) AS "id_estaciones",
    "array_agg"("estacion_nombre" ORDER BY "galones_total" DESC) AS "estaciones",
    "array_agg"("galones_total" ORDER BY "galones_total" DESC) AS "galones",
    "array_agg"("monto_total" ORDER BY "galones_total" DESC) AS "montos"
   FROM "base"
  GROUP BY "id_cliente", "razon_social";


ALTER VIEW "public"."vw_consumo_galones_por_estacion_mes_actual_arrays" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_consumo_galones_por_zona_mes_actual_arrays" WITH ("security_invoker"='on') AS
 WITH "base" AS (
         SELECT "z"."id_zona",
            "z"."nombre" AS "zona",
            "round"("sum"(COALESCE("a"."galones", (0)::numeric)), 2) AS "galones"
           FROM (("public"."cb_abastecimientos" "a"
             JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
             JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
          WHERE (("a"."fecha_hora" >= "date_trunc"('month'::"text", "now"())) AND ("a"."fecha_hora" < ("date_trunc"('month'::"text", "now"()) + '1 mon'::interval)))
          GROUP BY "z"."id_zona", "z"."nombre"
        ), "ordenado" AS (
         SELECT "base"."id_zona",
            "base"."zona",
            "base"."galones"
           FROM "base"
          ORDER BY "base"."galones" DESC
        )
 SELECT "to_json"("array_agg"("id_zona")) AS "zonas_id_lista",
    "to_json"("array_agg"("zona")) AS "zonas_nombre_lista",
    "to_json"("array_agg"("galones")) AS "galones_lista"
   FROM "ordenado";


ALTER VIEW "public"."vw_consumo_galones_por_zona_mes_actual_arrays" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_dashboard_admin_kpis_mes_actual" WITH ("security_invoker"='on') AS
 WITH "fechas" AS (
         SELECT "date_trunc"('month'::"text", "now"()) AS "mes_actual",
            ("date_trunc"('month'::"text", "now"()) - '1 mon'::interval) AS "mes_anterior"
        ), "abas" AS (
         SELECT "cb_abastecimientos"."id_abastecimiento",
            "cb_abastecimientos"."id_estacion",
            "cb_abastecimientos"."id_cliente",
            "cb_abastecimientos"."id_vehiculo",
            "cb_abastecimientos"."id_conductor",
            "cb_abastecimientos"."id_combustible",
            "cb_abastecimientos"."galones",
            "cb_abastecimientos"."total",
            "cb_abastecimientos"."kilometraje",
            "cb_abastecimientos"."fecha_hora",
            "cb_abastecimientos"."id_operador",
            "cb_abastecimientos"."qrgenerado",
            "cb_abastecimientos"."id_estado"
           FROM "public"."cb_abastecimientos"
        ), "galones" AS (
         SELECT "sum"(
                CASE
                    WHEN (("a"."fecha_hora" >= "f"."mes_actual") AND ("a"."fecha_hora" < ("f"."mes_actual" + '1 mon'::interval))) THEN COALESCE("a"."galones", (0)::numeric)
                    ELSE (0)::numeric
                END) AS "galones_actual",
            "sum"(
                CASE
                    WHEN (("a"."fecha_hora" >= "f"."mes_anterior") AND ("a"."fecha_hora" < "f"."mes_actual")) THEN COALESCE("a"."galones", (0)::numeric)
                    ELSE (0)::numeric
                END) AS "galones_anterior"
           FROM ("abas" "a"
             CROSS JOIN "fechas" "f")
        ), "montos" AS (
         SELECT "sum"(
                CASE
                    WHEN (("a"."fecha_hora" >= "f"."mes_actual") AND ("a"."fecha_hora" < ("f"."mes_actual" + '1 mon'::interval))) THEN COALESCE("a"."total", (0)::numeric)
                    ELSE (0)::numeric
                END) AS "monto_actual",
            "sum"(
                CASE
                    WHEN (("a"."fecha_hora" >= "f"."mes_anterior") AND ("a"."fecha_hora" < "f"."mes_actual")) THEN COALESCE("a"."total", (0)::numeric)
                    ELSE (0)::numeric
                END) AS "monto_anterior"
           FROM ("abas" "a"
             CROSS JOIN "fechas" "f")
        ), "tickets" AS (
         SELECT "count"(*) FILTER (WHERE (("a"."fecha_hora" >= "f"."mes_actual") AND ("a"."fecha_hora" < ("f"."mes_actual" + '1 mon'::interval)))) AS "tickets_actual",
            "count"(*) FILTER (WHERE (("a"."fecha_hora" >= "f"."mes_anterior") AND ("a"."fecha_hora" < "f"."mes_actual"))) AS "tickets_anterior"
           FROM ("abas" "a"
             CROSS JOIN "fechas" "f")
        )
 SELECT "g"."galones_actual",
    "g"."galones_anterior",
    "round"(
        CASE
            WHEN ("g"."galones_anterior" = (0)::numeric) THEN NULL::numeric
            ELSE ((("g"."galones_actual" - "g"."galones_anterior") / "g"."galones_anterior") * (100)::numeric)
        END, 2) AS "galones_variacion_pct",
        CASE
            WHEN ("g"."galones_anterior" = (0)::numeric) THEN false
            ELSE (("g"."galones_actual" - "g"."galones_anterior") > (0)::numeric)
        END AS "galones_variacion_positiva",
    "m"."monto_actual",
    "m"."monto_anterior",
    "round"(
        CASE
            WHEN ("m"."monto_anterior" = (0)::numeric) THEN NULL::numeric
            ELSE ((("m"."monto_actual" - "m"."monto_anterior") / "m"."monto_anterior") * (100)::numeric)
        END, 2) AS "monto_variacion_pct",
        CASE
            WHEN ("m"."monto_anterior" = (0)::numeric) THEN false
            ELSE (("m"."monto_actual" - "m"."monto_anterior") > (0)::numeric)
        END AS "monto_variacion_positiva",
    "t"."tickets_actual",
    "t"."tickets_anterior",
    "round"(
        CASE
            WHEN ("t"."tickets_anterior" = 0) THEN NULL::numeric
            ELSE (((("t"."tickets_actual" - "t"."tickets_anterior"))::numeric / ("t"."tickets_anterior")::numeric) * (100)::numeric)
        END, 2) AS "tickets_variacion_pct",
        CASE
            WHEN ("t"."tickets_anterior" = 0) THEN false
            ELSE (("t"."tickets_actual" - "t"."tickets_anterior") > 0)
        END AS "tickets_variacion_positiva"
   FROM (("galones" "g"
     CROSS JOIN "montos" "m")
     CROSS JOIN "tickets" "t");


ALTER VIEW "public"."vw_dashboard_admin_kpis_mes_actual" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_estaciones_cliente_combustible" WITH ("security_invoker"='on') AS
 SELECT DISTINCT "pc"."id_cliente",
    "pc"."id_combustible",
    "e"."id_estacion",
    "e"."nombre"
   FROM ("public"."cb_precios_combustible" "pc"
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "pc"."id_estacion")))
  WHERE (("pc"."estado" = true) AND ("e"."estado" = true));


ALTER VIEW "public"."vw_estaciones_cliente_combustible" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_estaciones_con_zona" WITH ("security_invoker"='on') AS
 WITH "fechas" AS (
         SELECT "date_trunc"('month'::"text", "now"()) AS "mes_actual"
        ), "galones_mes" AS (
         SELECT "a"."id_estacion",
            "sum"("a"."galones") AS "galones_mes_actual"
           FROM ("public"."cb_abastecimientos" "a"
             CROSS JOIN "fechas" "f")
          WHERE (("a"."fecha_hora" >= "f"."mes_actual") AND ("a"."fecha_hora" < ("f"."mes_actual" + '1 mon'::interval)))
          GROUP BY "a"."id_estacion"
        )
 SELECT "e"."id_estacion",
    "e"."nombre",
    "e"."ubicacion",
    "e"."id_tipo_estacion",
    "t"."nombre" AS "tipo_estacion",
    "e"."latitud",
    "e"."longitud",
    "e"."estado",
    "e"."id_zona",
    "z"."nombre" AS "nombre_zona",
    COALESCE("g"."galones_mes_actual", (0)::numeric) AS "galones_mes_actual"
   FROM ((("public"."ms_estaciones" "e"
     LEFT JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
     LEFT JOIN "public"."ms_tipos_estacion" "t" ON (("t"."id_tipo_estacion" = "e"."id_tipo_estacion")))
     LEFT JOIN "galones_mes" "g" ON (("g"."id_estacion" = "e"."id_estacion")));


ALTER VIEW "public"."vw_estaciones_con_zona" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_estaciones_dropdown" WITH ("security_invoker"='on') AS
 SELECT "id_estacion",
    "nombre"
   FROM ( SELECT 0 AS "id_estacion",
            'TODOS'::character varying AS "nombre"
        UNION ALL
         SELECT "e"."id_estacion",
            "e"."nombre"
           FROM "public"."ms_estaciones" "e"
          WHERE ("e"."estado" = true)) "t"
  ORDER BY
        CASE
            WHEN ("id_estacion" = 0) THEN 0
            ELSE 1
        END, "nombre";


ALTER VIEW "public"."vw_estaciones_dropdown" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_facturacion_abastecimientos_resumen" WITH ("security_invoker"='on') AS
 SELECT "a"."id_cliente",
    "c"."razon_social",
    "a"."fecha_facturacion",
    ("min"("a"."fecha_hora"))::"date" AS "fecha_inicio_consumo",
    ("max"("a"."fecha_hora"))::"date" AS "fecha_fin_consumo",
    (("a"."fecha_facturacion" + ((COALESCE(("pl"."plazo_de_pago")::integer, 0) || ' days'::"text"))::interval))::"date" AS "fecha_vencimiento",
    "count"(*) AS "cantidad_abastecimientos",
    "sum"("a"."galones") AS "total_galones",
    "sum"("a"."total") AS "total_monto",
    "array_agg"("a"."id_abastecimiento" ORDER BY "a"."id_abastecimiento") AS "abastecimientos_ids"
   FROM (("public"."cb_abastecimientos" "a"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "a"."id_cliente")))
     LEFT JOIN "public"."cb_lineas" "pl" ON ((("pl"."id_cliente" = "a"."id_cliente") AND ("pl"."estado" = true))))
  WHERE (("a"."fecha_facturacion" IS NOT NULL) AND ("a"."id_estado" = 2))
  GROUP BY "a"."id_cliente", "c"."razon_social", "a"."fecha_facturacion", "pl"."plazo_de_pago";


ALTER VIEW "public"."vw_facturacion_abastecimientos_resumen" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_historial_abastecimientos" AS
 SELECT "a"."id_abastecimiento",
    "a"."id_cliente",
    "a"."fecha_hora",
    "e"."id_estacion",
    "e"."nombre" AS "estacion",
    "cb"."id_combustible",
    "cb"."nombre" AS "tipo_combustible",
    "a"."galones",
    "round"(
        CASE
            WHEN ("a"."galones" > (0)::numeric) THEN ("a"."total" / "a"."galones")
            ELSE (0)::numeric
        END, 2) AS "precio_gal",
    "a"."total" AS "monto",
    "v"."id_vehiculo",
    "v"."placa" AS "vehiculo",
    "c"."id_conductor",
    "c"."nombre" AS "conductor"
   FROM (((("public"."cb_abastecimientos" "a"
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
     JOIN "public"."ms_combustibles" "cb" ON (("cb"."id_combustible" = "a"."id_combustible")))
     JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "a"."id_vehiculo")))
     JOIN "public"."ms_conductores" "c" ON (("c"."id_conductor" = "a"."id_conductor")))
  ORDER BY "a"."fecha_hora" DESC;


ALTER VIEW "public"."vw_historial_abastecimientos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_historial_precios_por_zona" WITH ("security_invoker"='on') AS
 SELECT "concat"('CLI', "pc"."id_cliente", '-Z', "z"."id_zona", '-C', "pc"."id_combustible", '-F', "to_char"("pc"."fecha_inicio", 'YYYYMMDDHH24MISS'::"text")) AS "version_id",
    "pc"."id_cliente",
    "c"."razon_social" AS "cliente",
    "z"."id_zona",
    "z"."nombre" AS "zona",
    NULL::integer AS "id_estacion",
    "pc"."id_combustible",
    "co"."nombre" AS "combustible",
    "pc"."precio",
    "pc"."fecha_inicio",
    "pc"."fecha_fin",
    "pc"."estado",
    "count"(DISTINCT "pc"."id_estacion") AS "estaciones_afectadas",
    "row_number"() OVER (PARTITION BY "pc"."id_cliente", "z"."id_zona", "pc"."id_combustible" ORDER BY "pc"."fecha_inicio") AS "version_orden"
   FROM (((("public"."cb_precios_combustible" "pc"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "pc"."id_cliente")))
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "pc"."id_estacion")))
     JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
     JOIN "public"."ms_combustibles" "co" ON (("co"."id_combustible" = "pc"."id_combustible")))
  WHERE ("z"."id_zona" <> 12)
  GROUP BY "pc"."id_cliente", "c"."razon_social", "z"."id_zona", "z"."nombre", "pc"."id_combustible", "co"."nombre", "pc"."precio", "pc"."fecha_inicio", "pc"."fecha_fin", "pc"."estado"
UNION ALL
 SELECT "concat"('CLI', "pc"."id_cliente", '-Z', "z"."id_zona", '-E', "e"."id_estacion", '-C', "pc"."id_combustible", '-F', "to_char"("pc"."fecha_inicio", 'YYYYMMDDHH24MISS'::"text")) AS "version_id",
    "pc"."id_cliente",
    "c"."razon_social" AS "cliente",
    "z"."id_zona",
    ((("z"."nombre")::"text" || ' - '::"text") || ("e"."nombre")::"text") AS "zona",
    "e"."id_estacion",
    "pc"."id_combustible",
    "co"."nombre" AS "combustible",
    "pc"."precio",
    "pc"."fecha_inicio",
    "pc"."fecha_fin",
    "pc"."estado",
    1 AS "estaciones_afectadas",
    "row_number"() OVER (PARTITION BY "pc"."id_cliente", "z"."id_zona", "e"."id_estacion", "pc"."id_combustible" ORDER BY "pc"."fecha_inicio") AS "version_orden"
   FROM (((("public"."cb_precios_combustible" "pc"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "pc"."id_cliente")))
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "pc"."id_estacion")))
     JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
     JOIN "public"."ms_combustibles" "co" ON (("co"."id_combustible" = "pc"."id_combustible")))
  WHERE ("z"."id_zona" = 12);


ALTER VIEW "public"."vw_historial_precios_por_zona" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_kpi_abastecimientos" WITH ("security_invoker"='on') AS
 SELECT "id_cliente",
    COALESCE("sum"("galones") FILTER (WHERE ("id_estado" = ANY (ARRAY[1, 2]))), (0)::numeric) AS "total_galones",
    COALESCE("sum"("total") FILTER (WHERE ("id_estado" = ANY (ARRAY[1, 2]))), (0)::numeric) AS "total_monto",
    "round"(COALESCE("avg"("total"), (0)::numeric), 2) AS "promedio_por_abastecimiento"
   FROM "public"."cb_abastecimientos" "a"
  GROUP BY "id_cliente";


ALTER VIEW "public"."vw_kpi_abastecimientos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_kpi_galones_mes_actual" WITH ("security_invoker"='on') AS
 WITH "fechas" AS (
         SELECT "date_trunc"('month'::"text", "now"()) AS "mes_actual"
        )
 SELECT COALESCE("sum"("a"."galones"), (0)::numeric) AS "galones_mes_actual"
   FROM ("public"."cb_abastecimientos" "a"
     CROSS JOIN "fechas" "f")
  WHERE (("a"."fecha_hora" >= "f"."mes_actual") AND ("a"."fecha_hora" < ("f"."mes_actual" + '1 mon'::interval)));


ALTER VIEW "public"."vw_kpi_galones_mes_actual" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_kpi_lineas_credito" WITH ("security_invoker"='on') AS
 WITH "clientes_activos" AS (
         SELECT DISTINCT "cb_lineas"."id_cliente"
           FROM "public"."cb_lineas"
          WHERE ("cb_lineas"."estado" = true)
        ), "totales" AS (
         SELECT ( SELECT COALESCE("sum"("cb_lineas"."monto_asignado"), (0)::numeric) AS "coalesce"
                   FROM "public"."cb_lineas"
                  WHERE ("cb_lineas"."estado" = true)) AS "total_asignado",
            ( SELECT COALESCE("sum"("a"."total"), (0)::numeric) AS "coalesce"
                   FROM ("public"."cb_abastecimientos" "a"
                     JOIN "clientes_activos" "ca" ON (("ca"."id_cliente" = "a"."id_cliente")))
                  WHERE ("a"."id_estado" = ANY (ARRAY[1, 2]))) AS "utilizado",
            ( SELECT "count"(*) AS "count"
                   FROM "public"."cb_lineas"
                  WHERE ("cb_lineas"."estado" = true)) AS "lineas_activas"
        )
 SELECT "total_asignado",
    "utilizado",
    ("total_asignado" - "utilizado") AS "disponible",
        CASE
            WHEN ("total_asignado" > (0)::numeric) THEN "round"(("utilizado" / "total_asignado"), 4)
            ELSE (0)::numeric
        END AS "ratio_utilizado",
        CASE
            WHEN ("total_asignado" > (0)::numeric) THEN "round"((("utilizado" / "total_asignado") * (100)::numeric), 2)
            ELSE (0)::numeric
        END AS "porcentaje_utilizado",
        CASE
            WHEN ("total_asignado" > (0)::numeric) THEN "round"((("total_asignado" - "utilizado") / "total_asignado"), 4)
            ELSE (0)::numeric
        END AS "ratio_disponible",
        CASE
            WHEN ("total_asignado" > (0)::numeric) THEN "round"(((("total_asignado" - "utilizado") / "total_asignado") * (100)::numeric), 2)
            ELSE (0)::numeric
        END AS "porcentaje_disponible",
    "lineas_activas"
   FROM "totales";


ALTER VIEW "public"."vw_kpi_lineas_credito" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_kpi_reporteglobal" WITH ("security_invoker"='on') AS
 SELECT "sum"("galones") AS "total_galones",
    "sum"("total") AS "monto_total",
    "count"("id_abastecimiento") AS "total_consumos",
    ("round"(
        CASE
            WHEN ("sum"("galones") > (0)::numeric) THEN ("sum"("total") / "sum"("galones"))
            ELSE (0)::numeric
        END, 2))::numeric(12,2) AS "precio_promedio"
   FROM "public"."cb_abastecimientos" "a";


ALTER VIEW "public"."vw_kpi_reporteglobal" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_lineas_credito_listado" WITH ("security_invoker"='on') AS
 SELECT "l"."id_linea",
    "l"."id_cliente",
    "l"."monto_asignado",
    "l"."estado",
    "l"."id_tipo_linea",
    "l"."id_periodo_facturacion",
    "l"."fecha_creacion",
    "l"."plazo_de_pago",
    "c"."razon_social" AS "cliente",
    "tl"."nombre" AS "tipo_linea",
    "pf"."nombre" AS "fecha_facturacion",
    COALESCE("ab"."total_utilizado", (0)::numeric) AS "utilizacion",
    GREATEST(("l"."monto_asignado" - COALESCE("ab"."total_utilizado", (0)::numeric)), (0)::numeric) AS "saldo_total_disponible",
        CASE
            WHEN ("l"."monto_asignado" > (0)::numeric) THEN "round"((COALESCE("ab"."total_utilizado", (0)::numeric) / "l"."monto_asignado"), 4)
            ELSE (0)::numeric
        END AS "porcentaje_utilizado",
        CASE
            WHEN ("l"."monto_asignado" > (0)::numeric) THEN "round"(((COALESCE("ab"."total_utilizado", (0)::numeric) / "l"."monto_asignado") * (100)::numeric), 2)
            ELSE (0)::numeric
        END AS "porcentaje_utilizado_100"
   FROM (((("public"."cb_lineas" "l"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "l"."id_cliente")))
     JOIN "public"."ms_tipos_linea_credito" "tl" ON (("tl"."id_tipo_linea" = "l"."id_tipo_linea")))
     LEFT JOIN "public"."ms_periodos_facturacion" "pf" ON (("pf"."id_periodo" = "l"."id_periodo_facturacion")))
     LEFT JOIN ( SELECT "a"."id_cliente",
            "sum"("a"."total") AS "total_utilizado"
           FROM "public"."cb_abastecimientos" "a"
          WHERE ("a"."id_estado" = ANY (ARRAY[1, 2]))
          GROUP BY "a"."id_cliente") "ab" ON (("ab"."id_cliente" = "l"."id_cliente")));


ALTER VIEW "public"."vw_lineas_credito_listado" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_movimientos_abastecimientos_simple" WITH ("security_invoker"='on') AS
 SELECT "a"."id_abastecimiento",
    "a"."id_cliente",
    "c"."razon_social",
    "a"."fecha_hora",
    ("a"."fecha_hora")::"date" AS "fecha",
    "v"."placa",
    "d"."nombre" AS "conductor",
    "e"."nombre" AS "estacion",
    "comb"."nombre" AS "combustible",
    "a"."galones",
    "a"."total",
    "a"."fecha_facturacion",
    "ef"."nombre" AS "estado_facturacion"
   FROM (((((("public"."cb_abastecimientos" "a"
     LEFT JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "a"."id_cliente")))
     LEFT JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "a"."id_vehiculo")))
     LEFT JOIN "public"."ms_conductores" "d" ON (("d"."id_conductor" = "a"."id_conductor")))
     LEFT JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
     LEFT JOIN "public"."ms_combustibles" "comb" ON (("comb"."id_combustible" = "a"."id_combustible")))
     LEFT JOIN "public"."ms_estados_facturacion" "ef" ON (("ef"."id_estado_facturacion" = "a"."id_estado")));


ALTER VIEW "public"."vw_movimientos_abastecimientos_simple" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_ms_centro_costo_con_default" WITH ("security_invoker"='on') AS
 SELECT "c"."id_centro_costo",
    "c"."nombre",
    "c"."id_cliente",
    "c"."estado",
    "c"."monto_asignado"
   FROM "public"."ms_centro_costo" "c"
  WHERE ("c"."monto_asignado" IS NOT NULL)
UNION ALL
 SELECT 0 AS "id_centro_costo",
    'Sin asignar'::character varying AS "nombre",
    NULL::integer AS "id_cliente",
    true AS "estado",
    NULL::numeric AS "monto_asignado";


ALTER VIEW "public"."vw_ms_centro_costo_con_default" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_ms_vehiculos_con_centro" WITH ("security_invoker"='on') AS
 SELECT "v"."id_vehiculo",
    "v"."placa",
    "v"."tipo",
    "v"."marca",
    "v"."anio",
    "v"."estado",
    "v"."id_cliente",
    "v"."modelo",
    COALESCE("v"."id_centro_costo", 0) AS "id_centro_costo",
    "v"."monto_asignado",
    "c"."nombre" AS "nombre_centro_costo"
   FROM ("public"."ms_vehiculos" "v"
     LEFT JOIN "public"."vw_ms_centro_costo_con_default" "c" ON ((COALESCE("v"."id_centro_costo", 0) = "c"."id_centro_costo")))
  WHERE (("v"."monto_asignado" IS NOT NULL) OR (EXISTS ( SELECT 1
           FROM "public"."cb_abastecimientos" "a"
          WHERE (("a"."id_vehiculo" = "v"."id_vehiculo") AND ("a"."id_estado" = ANY (ARRAY[1, 2]))))));


ALTER VIEW "public"."vw_ms_vehiculos_con_centro" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_operadores_estacion" WITH ("security_invoker"='on') AS
 SELECT "mop"."id_operador",
    "mop"."id_usuario",
    "mop"."id_estacion",
    "me"."nombre",
    "me"."id_zona"
   FROM ("public"."ms_operadores_estacion" "mop"
     JOIN "public"."ms_estaciones" "me" ON (("mop"."id_estacion" = "me"."id_estacion")));


ALTER VIEW "public"."vw_operadores_estacion" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_pagos_abastecimientos_resumen" WITH ("security_invoker"='on') AS
 SELECT "a"."id_cliente",
    "c"."razon_social",
    "a"."fecha_facturacion",
    "a"."fecha_pago",
    ("min"("a"."fecha_hora"))::"date" AS "fecha_inicio_consumo",
    ("max"("a"."fecha_hora"))::"date" AS "fecha_fin_consumo",
    "count"(*) AS "cantidad_abastecimientos",
    "sum"("a"."galones") AS "total_galones",
    "sum"("a"."total") AS "total_monto",
    "array_agg"("a"."id_abastecimiento" ORDER BY "a"."id_abastecimiento") AS "abastecimientos_ids"
   FROM ("public"."cb_abastecimientos" "a"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "a"."id_cliente")))
  WHERE (("a"."fecha_pago" IS NOT NULL) AND ("a"."id_estado" = 3))
  GROUP BY "a"."id_cliente", "c"."razon_social", "a"."fecha_facturacion", "a"."fecha_pago";


ALTER VIEW "public"."vw_pagos_abastecimientos_resumen" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_precios_combustible_cliente" WITH ("security_invoker"='on') AS
 SELECT "pc"."id_cliente",
    "pc"."id_estacion",
    "e"."nombre" AS "nombre_estacion",
    "pc"."id_combustible",
    "c"."nombre" AS "nombre_combustible",
    "pc"."precio",
    "pc"."fecha_inicio" AS "vigencia_desde"
   FROM (("public"."cb_precios_combustible" "pc"
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "pc"."id_estacion")))
     JOIN "public"."ms_combustibles" "c" ON (("c"."id_combustible" = "pc"."id_combustible")))
  WHERE ("pc"."estado" = true);


ALTER VIEW "public"."vw_precios_combustible_cliente" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_precios_vigentes_por_zona" WITH ("security_invoker"='on') AS
 SELECT "c"."id_cliente",
    "c"."ruc",
    "c"."razon_social",
    "z"."id_zona",
    "z"."nombre" AS "zona",
    NULL::integer AS "id_estacion",
    "comb"."id_combustible",
    "comb"."nombre" AS "combustible",
    "max"("p"."precio") AS "precio",
    "max"("p"."fecha_inicio") AS "fecha_inicio",
    "count"(DISTINCT "e"."id_estacion") AS "total_estaciones"
   FROM (((("public"."cb_precios_combustible" "p"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "p"."id_cliente")))
     JOIN "public"."ms_estaciones" "e" ON ((("e"."id_estacion" = "p"."id_estacion") AND ("e"."estado" = true))))
     JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
     JOIN "public"."ms_combustibles" "comb" ON (("comb"."id_combustible" = "p"."id_combustible")))
  WHERE (("p"."estado" = true) AND ("z"."id_zona" <> 12))
  GROUP BY "c"."id_cliente", "c"."ruc", "c"."razon_social", "z"."id_zona", "z"."nombre", "comb"."id_combustible", "comb"."nombre"
UNION ALL
 SELECT "c"."id_cliente",
    "c"."ruc",
    "c"."razon_social",
    "z"."id_zona",
    ((("z"."nombre")::"text" || ' - '::"text") || ("e"."nombre")::"text") AS "zona",
    "e"."id_estacion",
    "comb"."id_combustible",
    "comb"."nombre" AS "combustible",
    "max"("p"."precio") AS "precio",
    "max"("p"."fecha_inicio") AS "fecha_inicio",
    1 AS "total_estaciones"
   FROM (((("public"."cb_precios_combustible" "p"
     JOIN "public"."ms_clientes" "c" ON (("c"."id_cliente" = "p"."id_cliente")))
     JOIN "public"."ms_estaciones" "e" ON ((("e"."id_estacion" = "p"."id_estacion") AND ("e"."estado" = true))))
     JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
     JOIN "public"."ms_combustibles" "comb" ON (("comb"."id_combustible" = "p"."id_combustible")))
  WHERE (("p"."estado" = true) AND ("z"."id_zona" = 12))
  GROUP BY "c"."id_cliente", "c"."ruc", "c"."razon_social", "z"."id_zona", "z"."nombre", "e"."id_estacion", "e"."nombre", "comb"."id_combustible", "comb"."nombre";


ALTER VIEW "public"."vw_precios_vigentes_por_zona" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_qr_generados_detalle" WITH ("security_invoker"='on') AS
 SELECT "qr"."id_qr",
    "qr"."fecha_generada",
    "qr"."fecha_expiracion",
    "qr"."id_conductor",
    "c"."nombre" AS "nombre_conductor",
    "qr"."id_vehiculo",
    "v"."placa" AS "nombre_vehiculo",
    "v"."tipo" AS "tipo_vehiculo",
    "v"."id_cliente" AS "id_cliente_vehiculo",
    "qr"."id_combustible",
    "co"."nombre" AS "nombre_combustible",
    "qr"."id_estado",
    "e"."nombre" AS "nombre_estado",
    "qr"."id_estacion",
    "es"."nombre" AS "nombre_estacion",
    "cl"."id_cliente",
    "cl"."razon_social" AS "nombre_cliente"
   FROM (((((("public"."cb_qr_generados" "qr"
     LEFT JOIN "public"."ms_conductores" "c" ON (("c"."id_conductor" = "qr"."id_conductor")))
     LEFT JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "qr"."id_vehiculo")))
     LEFT JOIN "public"."ms_clientes" "cl" ON (("cl"."id_cliente" = "v"."id_cliente")))
     LEFT JOIN "public"."ms_combustibles" "co" ON (("co"."id_combustible" = "qr"."id_combustible")))
     LEFT JOIN "public"."ms_estados" "e" ON (("e"."id_estado" = "qr"."id_estado")))
     LEFT JOIN "public"."ms_estaciones" "es" ON (("es"."id_estacion" = "qr"."id_estacion")));


ALTER VIEW "public"."vw_qr_generados_detalle" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_reporte_estacion" WITH ("security_invoker"='on') AS
 SELECT "a"."id_cliente",
    "e"."id_estacion",
    "e"."nombre" AS "estacion",
    "c"."id_conductor",
    "c"."nombre" AS "conductor",
    "c"."dni",
    "v"."id_vehiculo",
    "v"."placa" AS "vehiculo",
    "v"."modelo",
    ("count"("a"."id_abastecimiento"))::integer AS "total_abastecimientos",
    COALESCE("sum"("a"."galones"), (0)::numeric) AS "total_galones",
    COALESCE("sum"("a"."total"), (0)::numeric) AS "total_monto"
   FROM ((("public"."cb_abastecimientos" "a"
     JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "a"."id_vehiculo")))
     JOIN "public"."ms_conductores" "c" ON (("c"."id_conductor" = "a"."id_conductor")))
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
  GROUP BY "a"."id_cliente", "e"."id_estacion", "e"."nombre", "c"."id_conductor", "c"."nombre", "c"."dni", "v"."id_vehiculo", "v"."placa", "v"."modelo"
  ORDER BY "a"."id_cliente", "e"."nombre", "c"."nombre", "v"."placa";


ALTER VIEW "public"."vw_reporte_estacion" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_reporte_vehiculo" WITH ("security_invoker"='on') AS
 SELECT "a"."id_cliente",
    "c"."id_conductor",
    "c"."nombre" AS "conductor",
    "c"."dni",
    "v"."id_vehiculo",
    "v"."placa" AS "vehiculo",
    "v"."modelo",
    ("count"("a"."id_abastecimiento"))::integer AS "total_abastecimientos",
    COALESCE("sum"("a"."galones"), (0)::numeric) AS "total_galones",
    COALESCE("sum"("a"."total"), (0)::numeric) AS "total_monto"
   FROM (("public"."cb_abastecimientos" "a"
     JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "a"."id_vehiculo")))
     JOIN "public"."ms_conductores" "c" ON (("c"."id_conductor" = "a"."id_conductor")))
  GROUP BY "a"."id_cliente", "c"."id_conductor", "c"."nombre", "c"."dni", "v"."id_vehiculo", "v"."placa", "v"."modelo"
  ORDER BY "a"."id_cliente", "c"."nombre", "v"."placa";


ALTER VIEW "public"."vw_reporte_vehiculo" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_reporteglobal_abastecimientos" WITH ("security_invoker"='on') AS
 SELECT "date_trunc"('day'::"text", "a"."fecha_hora") AS "fecha",
    "cl"."id_cliente",
    "cl"."razon_social" AS "cliente",
    "e"."id_estacion",
    "e"."nombre" AS "estacion",
    "z"."id_zona",
    "z"."nombre" AS "zona",
    "cb"."id_combustible",
    "cb"."nombre" AS "combustible",
    "sum"("a"."galones") AS "galones",
    "round"(
        CASE
            WHEN ("sum"("a"."galones") > (0)::numeric) THEN ("sum"("a"."total") / "sum"("a"."galones"))
            ELSE (0)::numeric
        END, 4) AS "precio_gal",
    "sum"("a"."total") AS "monto",
    "count"("a"."id_abastecimiento") AS "tickets"
   FROM (((("public"."cb_abastecimientos" "a"
     JOIN "public"."ms_clientes" "cl" ON (("cl"."id_cliente" = "a"."id_cliente")))
     JOIN "public"."ms_estaciones" "e" ON (("e"."id_estacion" = "a"."id_estacion")))
     LEFT JOIN "public"."ms_zonas" "z" ON (("z"."id_zona" = "e"."id_zona")))
     JOIN "public"."ms_combustibles" "cb" ON (("cb"."id_combustible" = "a"."id_combustible")))
  GROUP BY ("date_trunc"('day'::"text", "a"."fecha_hora")), "cl"."id_cliente", "cl"."razon_social", "e"."id_estacion", "e"."nombre", "z"."id_zona", "z"."nombre", "cb"."id_combustible", "cb"."nombre"
  ORDER BY ("date_trunc"('day'::"text", "a"."fecha_hora")) DESC, "cl"."razon_social", "e"."nombre";


ALTER VIEW "public"."vw_reporteglobal_abastecimientos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_tipos_estacion_conteo" WITH ("security_invoker"='on') AS
 SELECT "t"."id_tipo_estacion",
    "t"."nombre" AS "tipo_estacion",
    "count"("e"."id_estacion") AS "cantidad_estaciones"
   FROM ("public"."ms_tipos_estacion" "t"
     LEFT JOIN "public"."ms_estaciones" "e" ON (("e"."id_tipo_estacion" = "t"."id_tipo_estacion")))
  GROUP BY "t"."id_tipo_estacion", "t"."nombre";


ALTER VIEW "public"."vw_tipos_estacion_conteo" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_total_estaciones_por_zona_arrays" WITH ("security_invoker"='on') AS
 WITH "base" AS (
         SELECT "z"."nombre" AS "zona",
            "count"("e"."id_estacion") AS "total_estaciones"
           FROM ("public"."ms_zonas" "z"
             LEFT JOIN "public"."ms_estaciones" "e" ON ((("e"."id_zona" = "z"."id_zona") AND ("e"."estado" = true))))
          GROUP BY "z"."nombre"
          ORDER BY "z"."nombre"
        )
 SELECT "to_json"("array_agg"("zona")) AS "zonas_lista",
    "to_json"("array_agg"(("total_estaciones")::double precision)) AS "total_estaciones_lista"
   FROM "base";


ALTER VIEW "public"."vw_total_estaciones_por_zona_arrays" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_usuario_permisos_json" AS
 SELECT "u"."id_usuario",
    "u"."nombre",
    "u"."apellido",
    "u"."estado" AS "usuario_activo",
    COALESCE("r"."nombre", 'Sin Rol'::character varying) AS "rol",
        CASE
            WHEN ("u"."estado" = false) THEN '{"Estación": {"read": false, "create": false, "delete": false, "update": false}, "Facturación": {"read": false, "create": false, "delete": false, "update": false}, "Gestión de Precios": {"read": false, "create": false, "delete": false, "update": false}, "Líneas de Crédito": {"read": false, "create": false, "delete": false, "update": false}, "Usuarios y permisos": {"read": false, "create": false, "delete": false, "update": false}, "Clientes Corporativos": {"read": false, "create": false, "delete": false, "update": false}, "Reportes y Analíticas": {"read": false}, "Conciliar Abastecimientos": {"read": false, "create": false, "delete": false, "update": false}, "Asignación Vehículos - Conductor": {"read": false}}'::"jsonb"
            ELSE COALESCE("r"."permisos", '{"Estación": {"read": false, "create": false, "delete": false, "update": false}, "Facturación": {"read": false, "create": false, "delete": false, "update": false}, "Gestión de Precios": {"read": false, "create": false, "delete": false, "update": false}, "Líneas de Crédito": {"read": false, "create": false, "delete": false, "update": false}, "Usuarios y permisos": {"read": false, "create": false, "delete": false, "update": false}, "Clientes Corporativos": {"read": false, "create": false, "delete": false, "update": false}, "Reportes y Analíticas": {"read": false}, "Conciliar Abastecimientos": {"read": false, "create": false, "delete": false, "update": false}, "Asignación Vehículos - Conductor": {"read": false}}'::"jsonb")
        END AS "permisos"
   FROM ("public"."ms_usuarios" "u"
     LEFT JOIN "public"."ms_roles" "r" ON (("r"."id_rol" = "u"."id_rol")));


ALTER VIEW "public"."vw_usuario_permisos_json" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_usuarios_permisos_resumen" AS
 SELECT "u"."id_usuario",
    ((("u"."nombre")::"text" || ' '::"text") || (COALESCE("u"."apellido", ''::character varying))::"text") AS "usuario",
    COALESCE("r"."nombre", 'Sin Rol'::character varying) AS "rol",
    COALESCE("u"."estado", false) AS "usuario_activo",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Clientes Corporativos'::"text") ->> 'read'::"text"))::boolean, false)
        END AS "clientes_read",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Clientes Corporativos'::"text") ->> 'create'::"text"))::boolean, false)
        END AS "clientes_create",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Clientes Corporativos'::"text") ->> 'update'::"text"))::boolean, false)
        END AS "clientes_update",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Clientes Corporativos'::"text") ->> 'delete'::"text"))::boolean, false)
        END AS "clientes_delete",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Gestión de Precios'::"text") ->> 'read'::"text"))::boolean, false)
        END AS "precios_read",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Gestión de Precios'::"text") ->> 'create'::"text"))::boolean, false)
        END AS "precios_create",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Gestión de Precios'::"text") ->> 'update'::"text"))::boolean, false)
        END AS "precios_update",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Gestión de Precios'::"text") ->> 'delete'::"text"))::boolean, false)
        END AS "precios_delete",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Reportes y Analíticas'::"text") ->> 'read'::"text"))::boolean, false)
        END AS "reportes_read",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Facturación'::"text") ->> 'read'::"text"))::boolean, false)
        END AS "facturacion_read",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Facturación'::"text") ->> 'create'::"text"))::boolean, false)
        END AS "facturacion_create",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Facturación'::"text") ->> 'update'::"text"))::boolean, false)
        END AS "facturacion_update",
        CASE
            WHEN ("u"."estado" = false) THEN false
            ELSE COALESCE(((("r"."permisos" -> 'Facturación'::"text") ->> 'delete'::"text"))::boolean, false)
        END AS "facturacion_delete"
   FROM ("public"."ms_usuarios" "u"
     LEFT JOIN "public"."ms_roles" "r" ON (("r"."id_rol" = "u"."id_rol")));


ALTER VIEW "public"."vw_usuarios_permisos_resumen" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculo_combustible" WITH ("security_invoker"='on') AS
 SELECT "vc"."id_vehiculo",
    "vc"."id_combustible",
    "mc"."nombre"
   FROM ("public"."rl_vehiculo_combustible" "vc"
     JOIN "public"."ms_combustibles" "mc" ON (("vc"."id_combustible" = "mc"."id_combustible")));


ALTER VIEW "public"."vw_vehiculo_combustible" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculo_combustible_dropdown" WITH ("security_invoker"='on') AS
 SELECT "v"."id_vehiculo",
    "v"."placa",
    "v"."tipo",
    "c"."id_combustible",
    "c"."nombre"
   FROM (("public"."rl_vehiculo_combustible" "r"
     JOIN "public"."ms_vehiculos" "v" ON (("v"."id_vehiculo" = "r"."id_vehiculo")))
     JOIN "public"."ms_combustibles" "c" ON (("c"."id_combustible" = "r"."id_combustible")));


ALTER VIEW "public"."vw_vehiculo_combustible_dropdown" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculos_ccosto" WITH ("security_invoker"='on') AS
 SELECT "v"."id_vehiculo",
    "v"."placa",
    "v"."estado",
    "v"."id_centro_costo",
    "cc"."nombre" AS "nombre_centro_costo",
    "v"."id_cliente"
   FROM ("public"."ms_vehiculos" "v"
     LEFT JOIN "public"."ms_centro_costo" "cc" ON (("cc"."id_centro_costo" = "v"."id_centro_costo")));


ALTER VIEW "public"."vw_vehiculos_ccosto" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculos_con_combustibles" AS
SELECT
    NULL::integer AS "id_vehiculo",
    NULL::character varying(20) AS "placa",
    NULL::character varying(50) AS "tipo",
    NULL::character varying(150) AS "marca",
    NULL::integer AS "anio",
    NULL::boolean AS "estado",
    NULL::integer AS "id_cliente",
    NULL::character varying AS "modelo",
    NULL::integer AS "id_centro_costo",
    NULL::numeric AS "monto_asignado",
    NULL::integer[] AS "combustible_ids",
    NULL::character varying[] AS "combustible_nombres";


ALTER VIEW "public"."vw_vehiculos_con_combustibles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculos_conductores_asignaciones" WITH ("security_invoker"='on') AS
 SELECT "ac"."id_asignacion",
    "ac"."id_vehiculo",
    "mv"."placa",
    "mv"."tipo",
    "ac"."id_conductor",
    "mc"."nombre" AS "conductor",
    "mc"."id_cliente",
    "mcl"."razon_social",
    "ac"."fecha_inicio",
    "ac"."fecha_fin",
    "ac"."estado" AS "asignacion_activa",
    "mv"."estado" AS "vehiculo_activo"
   FROM ((("public"."cb_asignaciones_conductor" "ac"
     JOIN "public"."ms_vehiculos" "mv" ON (("ac"."id_vehiculo" = "mv"."id_vehiculo")))
     JOIN "public"."ms_conductores" "mc" ON (("ac"."id_conductor" = "mc"."id_conductor")))
     JOIN "public"."ms_clientes" "mcl" ON (("mc"."id_cliente" = "mcl"."id_cliente")))
  WHERE (("ac"."estado" = true) AND ("mv"."estado" = true) AND ("ac"."fecha_inicio" <= CURRENT_DATE) AND (("ac"."fecha_fin" IS NULL) OR (CURRENT_DATE <= "ac"."fecha_fin")));


ALTER VIEW "public"."vw_vehiculos_conductores_asignaciones" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculos_conductores_cliente" WITH ("security_invoker"='on') AS
 SELECT "ac"."id_vehiculo",
    "mv"."placa",
    "mv"."tipo",
    "ac"."id_conductor",
    "mc"."nombre",
    "mc"."id_cliente",
    "mcl"."razon_social",
    "mv"."estado"
   FROM ((("public"."cb_asignaciones_conductor" "ac"
     JOIN "public"."ms_vehiculos" "mv" ON (("ac"."id_vehiculo" = "mv"."id_vehiculo")))
     JOIN "public"."ms_conductores" "mc" ON (("ac"."id_conductor" = "mc"."id_conductor")))
     JOIN "public"."ms_clientes" "mcl" ON (("mc"."id_cliente" = "mcl"."id_cliente")));


ALTER VIEW "public"."vw_vehiculos_conductores_cliente" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculos_consumo_resumen" WITH ("security_invoker"='on') AS
 SELECT "v"."id_vehiculo",
    "v"."placa",
    "v"."tipo",
    "v"."marca",
    "v"."modelo",
    "v"."anio",
    "v"."estado",
    "v"."monto_asignado",
    "v"."id_cliente",
    "v"."id_centro_costo",
    "cc"."nombre" AS "nombre_centro_costo",
    "v"."monto_asignado" AS "monto_asignado_vehiculo",
    COALESCE("sum"("a"."total"), (0)::numeric) AS "total_abastecido_estados_1_2",
    "count"("a"."id_abastecimiento") AS "cantidad_abastecimientos"
   FROM (("public"."ms_vehiculos" "v"
     LEFT JOIN "public"."ms_centro_costo" "cc" ON (("cc"."id_centro_costo" = "v"."id_centro_costo")))
     LEFT JOIN "public"."cb_abastecimientos" "a" ON ((("a"."id_vehiculo" = "v"."id_vehiculo") AND ("a"."id_estado" = ANY (ARRAY[1, 2])))))
  GROUP BY "v"."id_vehiculo", "v"."placa", "v"."tipo", "v"."marca", "v"."modelo", "v"."anio", "v"."estado", "v"."monto_asignado", "v"."id_cliente", "v"."id_centro_costo", "cc"."nombre"
 HAVING ((("v"."monto_asignado" IS NOT NULL) AND ("v"."monto_asignado" > (0)::numeric)) OR ("count"("a"."id_abastecimiento") > 0));


ALTER VIEW "public"."vw_vehiculos_consumo_resumen" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculos_estado" WITH ("security_invoker"='on') AS
 SELECT "v"."id_vehiculo",
    "v"."estado",
    "v"."id_centro_costo",
    "v"."id_cliente",
    (((("v"."placa")::"text" || ' | Monto: S/ '::"text") ||
        CASE
            WHEN (COALESCE("v"."monto_asignado", (0)::numeric) = (0)::numeric) THEN '0'::"text"
            WHEN (COALESCE("v"."monto_asignado", (0)::numeric) = "floor"(COALESCE("v"."monto_asignado", (0)::numeric))) THEN "to_char"(COALESCE("v"."monto_asignado", (0)::numeric), 'FM999G999G999'::"text")
            ELSE "to_char"(COALESCE("v"."monto_asignado", (0)::numeric), 'FM999G999G999D00'::"text")
        END) ||
        CASE
            WHEN (COALESCE("consumido"."total_consumido", (0)::numeric) > (0)::numeric) THEN (' | Consumido: S/ '::"text" ||
            CASE
                WHEN ("consumido"."total_consumido" = "floor"("consumido"."total_consumido")) THEN "to_char"("consumido"."total_consumido", 'FM999G999G999'::"text")
                ELSE "to_char"("consumido"."total_consumido", 'FM999G999G999D00'::"text")
            END)
            ELSE ''::"text"
        END) AS "placa_monto"
   FROM ("public"."ms_vehiculos" "v"
     LEFT JOIN ( SELECT "a"."id_vehiculo",
            "sum"("a"."total") AS "total_consumido"
           FROM "public"."cb_abastecimientos" "a"
          WHERE ("a"."id_estado" = ANY (ARRAY[1, 2]))
          GROUP BY "a"."id_vehiculo") "consumido" ON (("consumido"."id_vehiculo" = "v"."id_vehiculo")))
  WHERE ("v"."estado" = true);


ALTER VIEW "public"."vw_vehiculos_estado" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_vehiculos_sin_asignar" WITH ("security_invoker"='on') AS
 SELECT "v"."id_cliente",
    ("count"("v"."id_vehiculo"))::integer AS "vehiculos_sin_asignar"
   FROM ("public"."ms_vehiculos" "v"
     LEFT JOIN "public"."cb_asignaciones_conductor" "a" ON ((("a"."id_vehiculo" = "v"."id_vehiculo") AND ("a"."estado" = true) AND (("a"."fecha_fin" IS NULL) OR ("a"."fecha_fin" >= CURRENT_DATE)))))
  WHERE (("v"."estado" = true) AND ("a"."id_asignacion" IS NULL))
  GROUP BY "v"."id_cliente";


ALTER VIEW "public"."vw_vehiculos_sin_asignar" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vw_zonas_con_estaciones" WITH ("security_invoker"='on') AS
 SELECT "z"."id_zona",
    "z"."nombre",
    "count"("e"."id_estacion") AS "cantidad_estaciones"
   FROM ("public"."ms_zonas" "z"
     LEFT JOIN "public"."ms_estaciones" "e" ON (("e"."id_zona" = "z"."id_zona")))
  GROUP BY "z"."id_zona", "z"."nombre";


ALTER VIEW "public"."vw_zonas_con_estaciones" OWNER TO "postgres";


ALTER TABLE ONLY "public"."auditoria" ALTER COLUMN "id_evento" SET DEFAULT "nextval"('"public"."auditoria_id_evento_seq"'::"regclass");



ALTER TABLE ONLY "public"."cb_abastecimientos" ALTER COLUMN "id_abastecimiento" SET DEFAULT "nextval"('"public"."cb_abastecimientos_id_abastecimiento_seq"'::"regclass");



ALTER TABLE ONLY "public"."cb_asignaciones_conductor" ALTER COLUMN "id_asignacion" SET DEFAULT "nextval"('"public"."cb_asignaciones_conductor_id_asignacion_seq"'::"regclass");



ALTER TABLE ONLY "public"."cb_facturacion" ALTER COLUMN "id_factura" SET DEFAULT "nextval"('"public"."cb_facturacion_id_factura_seq"'::"regclass");



ALTER TABLE ONLY "public"."cb_lineas" ALTER COLUMN "id_linea" SET DEFAULT "nextval"('"public"."cb_lineas_id_linea_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_clientes" ALTER COLUMN "id_cliente" SET DEFAULT "nextval"('"public"."ms_clientes_id_cliente_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_combustibles" ALTER COLUMN "id_combustible" SET DEFAULT "nextval"('"public"."ms_combustibles_id_combustible_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_conductores" ALTER COLUMN "id_conductor" SET DEFAULT "nextval"('"public"."ms_conductores_id_conductor_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_estaciones" ALTER COLUMN "id_estacion" SET DEFAULT "nextval"('"public"."ms_estaciones_id_estacion_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_estados" ALTER COLUMN "id_estado" SET DEFAULT "nextval"('"public"."ms_estados_id_estado_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_operadores_estacion" ALTER COLUMN "id_operador" SET DEFAULT "nextval"('"public"."ms_operadores_estacion_id_operador_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_proveedores" ALTER COLUMN "id_proveedor" SET DEFAULT "nextval"('"public"."ms_proveedores_id_proveedor_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_vehiculos" ALTER COLUMN "id_vehiculo" SET DEFAULT "nextval"('"public"."ms_vehiculos_id_vehiculo_seq"'::"regclass");



ALTER TABLE ONLY "public"."ms_zonas" ALTER COLUMN "id_zona" SET DEFAULT "nextval"('"public"."ms_zonas_id_zona_seq"'::"regclass");



ALTER TABLE ONLY "public"."pagos" ALTER COLUMN "id_pago" SET DEFAULT "nextval"('"public"."pagos_id_pago_seq"'::"regclass");



ALTER TABLE ONLY "public"."auditoria"
    ADD CONSTRAINT "auditoria_pkey" PRIMARY KEY ("id_evento");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_pkey" PRIMARY KEY ("id_abastecimiento");



ALTER TABLE ONLY "public"."cb_asignaciones_conductor"
    ADD CONSTRAINT "cb_asignaciones_conductor_pkey" PRIMARY KEY ("id_asignacion");



ALTER TABLE ONLY "public"."cb_facturacion"
    ADD CONSTRAINT "cb_facturacion_pkey" PRIMARY KEY ("id_factura");



ALTER TABLE ONLY "public"."cb_lineas"
    ADD CONSTRAINT "cb_lineas_pkey" PRIMARY KEY ("id_linea");



ALTER TABLE ONLY "public"."cb_precios_combustible"
    ADD CONSTRAINT "cb_precios_combustible_pkey" PRIMARY KEY ("id_precio");



ALTER TABLE ONLY "public"."cb_qr_generados"
    ADD CONSTRAINT "cb_qr_generados_pkey" PRIMARY KEY ("id_qr");



ALTER TABLE ONLY "public"."ms_centro_costo"
    ADD CONSTRAINT "ms_ceentro_costo_pkey" PRIMARY KEY ("id_centro_costo");



ALTER TABLE ONLY "public"."ms_clientes"
    ADD CONSTRAINT "ms_clientes_pkey" PRIMARY KEY ("id_cliente");



ALTER TABLE ONLY "public"."ms_clientes"
    ADD CONSTRAINT "ms_clientes_ruc_key" UNIQUE ("ruc");



ALTER TABLE ONLY "public"."ms_combustibles"
    ADD CONSTRAINT "ms_combustibles_pkey" PRIMARY KEY ("id_combustible");



ALTER TABLE ONLY "public"."ms_conductores"
    ADD CONSTRAINT "ms_conductores_dni_key" UNIQUE ("dni");



ALTER TABLE ONLY "public"."ms_conductores"
    ADD CONSTRAINT "ms_conductores_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."ms_conductores"
    ADD CONSTRAINT "ms_conductores_licencia_key" UNIQUE ("licencia");



ALTER TABLE ONLY "public"."ms_conductores"
    ADD CONSTRAINT "ms_conductores_pkey" PRIMARY KEY ("id_conductor");



ALTER TABLE ONLY "public"."ms_contactos_cliente"
    ADD CONSTRAINT "ms_contactos_cliente_pkey" PRIMARY KEY ("id_contacto");



ALTER TABLE ONLY "public"."ms_estaciones"
    ADD CONSTRAINT "ms_estaciones_pkey" PRIMARY KEY ("id_estacion");



ALTER TABLE ONLY "public"."ms_estados_facturacion"
    ADD CONSTRAINT "ms_estados_facturacion_nombre_key" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."ms_estados_facturacion"
    ADD CONSTRAINT "ms_estados_facturacion_pkey" PRIMARY KEY ("id_estado_facturacion");



ALTER TABLE ONLY "public"."ms_estados"
    ADD CONSTRAINT "ms_estados_nombre_key" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."ms_estados"
    ADD CONSTRAINT "ms_estados_pkey" PRIMARY KEY ("id_estado");



ALTER TABLE ONLY "public"."ms_feriados"
    ADD CONSTRAINT "ms_feriados_pkey" PRIMARY KEY ("fecha");



ALTER TABLE ONLY "public"."ms_operadores_estacion"
    ADD CONSTRAINT "ms_operadores_estacion_pkey" PRIMARY KEY ("id_operador");



ALTER TABLE ONLY "public"."ms_periodos_facturacion"
    ADD CONSTRAINT "ms_periodos_facturacion_nombre_key" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."ms_periodos_facturacion"
    ADD CONSTRAINT "ms_periodos_facturacion_pkey" PRIMARY KEY ("id_periodo");



ALTER TABLE ONLY "public"."ms_proveedores"
    ADD CONSTRAINT "ms_proveedores_pkey" PRIMARY KEY ("id_proveedor");



ALTER TABLE ONLY "public"."ms_roles"
    ADD CONSTRAINT "ms_roles_nombre_key" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."ms_roles"
    ADD CONSTRAINT "ms_roles_pkey" PRIMARY KEY ("id_rol");



ALTER TABLE ONLY "public"."ms_tipos_estacion"
    ADD CONSTRAINT "ms_tipos_estacion_nombre_key" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."ms_tipos_estacion"
    ADD CONSTRAINT "ms_tipos_estacion_pkey" PRIMARY KEY ("id_tipo_estacion");



ALTER TABLE ONLY "public"."ms_tipos_linea_credito"
    ADD CONSTRAINT "ms_tipos_linea_credito_nombre_key" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."ms_tipos_linea_credito"
    ADD CONSTRAINT "ms_tipos_linea_credito_pkey" PRIMARY KEY ("id_tipo_linea");



ALTER TABLE ONLY "public"."ms_usuarios"
    ADD CONSTRAINT "ms_usuarios_pkey" PRIMARY KEY ("id_usuario");



ALTER TABLE ONLY "public"."ms_vehiculos"
    ADD CONSTRAINT "ms_vehiculos_pkey" PRIMARY KEY ("id_vehiculo");



ALTER TABLE ONLY "public"."ms_vehiculos"
    ADD CONSTRAINT "ms_vehiculos_placa_key" UNIQUE ("placa");



ALTER TABLE ONLY "public"."ms_zonas"
    ADD CONSTRAINT "ms_zonas_pkey" PRIMARY KEY ("id_zona");



ALTER TABLE ONLY "public"."pagos"
    ADD CONSTRAINT "pagos_pkey" PRIMARY KEY ("id_pago");



ALTER TABLE ONLY "public"."rl_proveedor_estacion"
    ADD CONSTRAINT "rl_proveedor_estacion_pkey" PRIMARY KEY ("id_proveedor", "id_estacion");



ALTER TABLE ONLY "public"."rl_vehiculo_combustible"
    ADD CONSTRAINT "rl_vehiculo_combustible_pkey" PRIMARY KEY ("id_vehiculo", "id_combustible");



CREATE INDEX "idx_asignaciones_estado_fecha_fin" ON "public"."cb_asignaciones_conductor" USING "btree" ("estado", "fecha_fin");



CREATE UNIQUE INDEX "uq_cb_abastecimientos_qrgenerado" ON "public"."cb_abastecimientos" USING "btree" ("qrgenerado");



CREATE UNIQUE INDEX "uq_contacto_principal_por_cliente" ON "public"."ms_contactos_cliente" USING "btree" ("id_cliente") WHERE ("contactoPrincipal" = true);



CREATE UNIQUE INDEX "uq_precio_activo" ON "public"."cb_precios_combustible" USING "btree" ("id_cliente", "id_estacion", "id_combustible") WHERE ("estado" = true);



CREATE UNIQUE INDEX "ux_asignacion_conductor_vehiculo_activa" ON "public"."cb_asignaciones_conductor" USING "btree" ("id_vehiculo", "id_conductor") WHERE ("estado" = true);



CREATE OR REPLACE VIEW "public"."vw_vehiculos_con_combustibles" WITH ("security_invoker"='on') AS
 SELECT "v"."id_vehiculo",
    "v"."placa",
    "v"."tipo",
    "v"."marca",
    "v"."anio",
    "v"."estado",
    "v"."id_cliente",
    "v"."modelo",
    "v"."id_centro_costo",
    "v"."monto_asignado",
    COALESCE("array_agg"(DISTINCT "c"."id_combustible") FILTER (WHERE ("c"."id_combustible" IS NOT NULL)), '{}'::integer[]) AS "combustible_ids",
    COALESCE("array_agg"(DISTINCT "c"."nombre") FILTER (WHERE ("c"."nombre" IS NOT NULL)), '{}'::character varying[]) AS "combustible_nombres"
   FROM (("public"."ms_vehiculos" "v"
     LEFT JOIN "public"."rl_vehiculo_combustible" "r" ON (("r"."id_vehiculo" = "v"."id_vehiculo")))
     LEFT JOIN "public"."ms_combustibles" "c" ON (("c"."id_combustible" = "r"."id_combustible")))
  GROUP BY "v"."id_vehiculo";



CREATE OR REPLACE TRIGGER "trg_set_default_permisos" BEFORE INSERT ON "public"."ms_roles" FOR EACH ROW EXECUTE FUNCTION "public"."fn_set_default_permisos"();



ALTER TABLE ONLY "public"."auditoria"
    ADD CONSTRAINT "auditoria_usuario_auth_fkey" FOREIGN KEY ("usuario") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_id_cliente_fkey" FOREIGN KEY ("id_cliente") REFERENCES "public"."ms_clientes"("id_cliente");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_id_combustible_fkey" FOREIGN KEY ("id_combustible") REFERENCES "public"."ms_combustibles"("id_combustible");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_id_conductor_fkey" FOREIGN KEY ("id_conductor") REFERENCES "public"."ms_conductores"("id_conductor");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_id_estacion_fkey" FOREIGN KEY ("id_estacion") REFERENCES "public"."ms_estaciones"("id_estacion");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_id_estado_fkey" FOREIGN KEY ("id_estado") REFERENCES "public"."ms_estados_facturacion"("id_estado_facturacion");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_id_operador_fkey" FOREIGN KEY ("id_operador") REFERENCES "public"."ms_operadores_estacion"("id_operador");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_id_precio_fkey" FOREIGN KEY ("id_precio") REFERENCES "public"."cb_precios_combustible"("id_precio");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_id_vehiculo_fkey" FOREIGN KEY ("id_vehiculo") REFERENCES "public"."ms_vehiculos"("id_vehiculo");



ALTER TABLE ONLY "public"."cb_abastecimientos"
    ADD CONSTRAINT "cb_abastecimientos_qrgenerado_fkey" FOREIGN KEY ("qrgenerado") REFERENCES "public"."cb_qr_generados"("id_qr");



ALTER TABLE ONLY "public"."cb_asignaciones_conductor"
    ADD CONSTRAINT "cb_asignaciones_conductor_id_conductor_fkey" FOREIGN KEY ("id_conductor") REFERENCES "public"."ms_conductores"("id_conductor");



ALTER TABLE ONLY "public"."cb_asignaciones_conductor"
    ADD CONSTRAINT "cb_asignaciones_conductor_id_vehiculo_fkey" FOREIGN KEY ("id_vehiculo") REFERENCES "public"."ms_vehiculos"("id_vehiculo");



ALTER TABLE ONLY "public"."cb_facturacion"
    ADD CONSTRAINT "cb_facturacion_id_cliente_fkey" FOREIGN KEY ("id_cliente") REFERENCES "public"."ms_clientes"("id_cliente");



ALTER TABLE ONLY "public"."cb_lineas"
    ADD CONSTRAINT "cb_lineas_id_cliente_fkey" FOREIGN KEY ("id_cliente") REFERENCES "public"."ms_clientes"("id_cliente");



ALTER TABLE ONLY "public"."cb_lineas"
    ADD CONSTRAINT "cb_lineas_periodo_facturacion_fkey" FOREIGN KEY ("id_periodo_facturacion") REFERENCES "public"."ms_periodos_facturacion"("id_periodo");



ALTER TABLE ONLY "public"."cb_lineas"
    ADD CONSTRAINT "cb_lineas_tipo_linea_fkey" FOREIGN KEY ("id_tipo_linea") REFERENCES "public"."ms_tipos_linea_credito"("id_tipo_linea");



ALTER TABLE ONLY "public"."cb_precios_combustible"
    ADD CONSTRAINT "cb_precios_combustible_id_cliente_fkey" FOREIGN KEY ("id_cliente") REFERENCES "public"."ms_clientes"("id_cliente");



ALTER TABLE ONLY "public"."cb_precios_combustible"
    ADD CONSTRAINT "cb_precios_combustible_id_combustible_fkey" FOREIGN KEY ("id_combustible") REFERENCES "public"."ms_combustibles"("id_combustible");



ALTER TABLE ONLY "public"."cb_precios_combustible"
    ADD CONSTRAINT "cb_precios_combustible_id_estacion_fkey" FOREIGN KEY ("id_estacion") REFERENCES "public"."ms_estaciones"("id_estacion");



ALTER TABLE ONLY "public"."cb_qr_generados"
    ADD CONSTRAINT "cb_qr_generados_id_combustible_fkey" FOREIGN KEY ("id_combustible") REFERENCES "public"."ms_combustibles"("id_combustible");



ALTER TABLE ONLY "public"."cb_qr_generados"
    ADD CONSTRAINT "cb_qr_generados_id_conductor_fkey" FOREIGN KEY ("id_conductor") REFERENCES "public"."ms_conductores"("id_conductor");



ALTER TABLE ONLY "public"."cb_qr_generados"
    ADD CONSTRAINT "cb_qr_generados_id_estacion_fkey" FOREIGN KEY ("id_estacion") REFERENCES "public"."ms_estaciones"("id_estacion");



ALTER TABLE ONLY "public"."cb_qr_generados"
    ADD CONSTRAINT "cb_qr_generados_id_estado_fkey" FOREIGN KEY ("id_estado") REFERENCES "public"."ms_estados"("id_estado");



ALTER TABLE ONLY "public"."cb_qr_generados"
    ADD CONSTRAINT "cb_qr_generados_id_vehiculo_fkey" FOREIGN KEY ("id_vehiculo") REFERENCES "public"."ms_vehiculos"("id_vehiculo");



ALTER TABLE ONLY "public"."ms_estaciones"
    ADD CONSTRAINT "fk_estaciones_tipo" FOREIGN KEY ("id_tipo_estacion") REFERENCES "public"."ms_tipos_estacion"("id_tipo_estacion");



ALTER TABLE ONLY "public"."ms_estaciones"
    ADD CONSTRAINT "fk_estaciones_zona" FOREIGN KEY ("id_zona") REFERENCES "public"."ms_zonas"("id_zona");



ALTER TABLE ONLY "public"."ms_centro_costo"
    ADD CONSTRAINT "ms_ceentro_costo_id_cliente_fkey" FOREIGN KEY ("id_cliente") REFERENCES "public"."ms_clientes"("id_cliente");



ALTER TABLE ONLY "public"."ms_conductores"
    ADD CONSTRAINT "ms_conductores_id_cliente_fkey" FOREIGN KEY ("id_cliente") REFERENCES "public"."ms_clientes"("id_cliente");



ALTER TABLE ONLY "public"."ms_conductores"
    ADD CONSTRAINT "ms_conductores_id_usuario_fkey" FOREIGN KEY ("id_usuario") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ms_contactos_cliente"
    ADD CONSTRAINT "ms_contactos_cliente_id_cliente_fkey" FOREIGN KEY ("id_cliente") REFERENCES "public"."ms_clientes"("id_cliente");



ALTER TABLE ONLY "public"."ms_contactos_cliente"
    ADD CONSTRAINT "ms_contactos_cliente_id_contacto_fkey" FOREIGN KEY ("id_contacto") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ms_operadores_estacion"
    ADD CONSTRAINT "ms_operadores_estacion_id_estacion_fkey" FOREIGN KEY ("id_estacion") REFERENCES "public"."ms_estaciones"("id_estacion");



ALTER TABLE ONLY "public"."ms_operadores_estacion"
    ADD CONSTRAINT "ms_operadores_estacion_id_usuario_fkey" FOREIGN KEY ("id_usuario") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ms_usuarios"
    ADD CONSTRAINT "ms_usuarios_id_rol_fkey" FOREIGN KEY ("id_rol") REFERENCES "public"."ms_roles"("id_rol");



ALTER TABLE ONLY "public"."ms_usuarios"
    ADD CONSTRAINT "ms_usuarios_id_usuario_fkey" FOREIGN KEY ("id_usuario") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ms_vehiculos"
    ADD CONSTRAINT "ms_vehiculos_id_centro_costo_fkey" FOREIGN KEY ("id_centro_costo") REFERENCES "public"."ms_centro_costo"("id_centro_costo");



ALTER TABLE ONLY "public"."ms_vehiculos"
    ADD CONSTRAINT "ms_vehiculos_id_cliente_fkey" FOREIGN KEY ("id_cliente") REFERENCES "public"."ms_clientes"("id_cliente");



ALTER TABLE ONLY "public"."pagos"
    ADD CONSTRAINT "pagos_id_linea_fkey" FOREIGN KEY ("id_linea") REFERENCES "public"."cb_lineas"("id_linea");



ALTER TABLE ONLY "public"."rl_proveedor_estacion"
    ADD CONSTRAINT "rl_proveedor_estacion_id_estacion_fkey" FOREIGN KEY ("id_estacion") REFERENCES "public"."ms_estaciones"("id_estacion");



ALTER TABLE ONLY "public"."rl_proveedor_estacion"
    ADD CONSTRAINT "rl_proveedor_estacion_id_proveedor_fkey" FOREIGN KEY ("id_proveedor") REFERENCES "public"."ms_proveedores"("id_proveedor");



ALTER TABLE ONLY "public"."rl_vehiculo_combustible"
    ADD CONSTRAINT "rl_vehiculo_combustible_id_combustible_fkey" FOREIGN KEY ("id_combustible") REFERENCES "public"."ms_combustibles"("id_combustible");



ALTER TABLE ONLY "public"."rl_vehiculo_combustible"
    ADD CONSTRAINT "rl_vehiculo_combustible_id_vehiculo_fkey" FOREIGN KEY ("id_vehiculo") REFERENCES "public"."ms_vehiculos"("id_vehiculo");



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."auditoria" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."cb_abastecimientos" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."cb_asignaciones_conductor" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."cb_facturacion" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."cb_lineas" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."cb_precios_combustible" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."cb_qr_generados" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."ms_centro_costo" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Insert" ON "public"."ms_clientes" FOR INSERT TO "authenticated" WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."auditoria" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."cb_abastecimientos" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."cb_asignaciones_conductor" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."cb_facturacion" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."cb_lineas" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."cb_precios_combustible" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."cb_qr_generados" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."ms_centro_costo" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Select" ON "public"."ms_clientes" FOR SELECT TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."auditoria" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."cb_abastecimientos" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."cb_asignaciones_conductor" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."cb_facturacion" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."cb_lineas" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."cb_precios_combustible" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."cb_qr_generados" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."ms_centro_costo" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Usuarios autenticados_Update" ON "public"."ms_clientes" FOR UPDATE TO "authenticated" USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."auditoria" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cb_abastecimientos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cb_asignaciones_conductor" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cb_facturacion" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cb_lineas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cb_precios_combustible" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cb_qr_generados" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ms_centro_costo" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ms_clientes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tmp_read_cb_abastecimientos" ON "public"."cb_abastecimientos" FOR SELECT USING (true);





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."cb_abastecimientos";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."cb_qr_generados";






REVOKE USAGE ON SCHEMA "public" FROM PUBLIC;
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."fn_ajuste_masivo_precios_excel"("p_filas" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_ajuste_masivo_precios_excel"("p_filas" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_ajuste_masivo_precios_excel"("p_filas" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_calc_cierre"("p_periodo_id" integer, "p_hoy" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_calc_cierre"("p_periodo_id" integer, "p_hoy" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_calc_cierre"("p_periodo_id" integer, "p_hoy" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_cierre_facturacion"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_cierre_facturacion"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_cierre_facturacion"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_cierre_facturacion_test"("p_hoy" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_cierre_facturacion_test"("p_hoy" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_cierre_facturacion_test"("p_hoy" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_es_no_habil"("p_fecha" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_es_no_habil"("p_fecha" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_es_no_habil"("p_fecha" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_kpi_global"("p_cliente" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_kpi_global"("p_cliente" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_kpi_global"("p_cliente" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_registrar_abastecimiento"("p_id_cliente" integer, "p_id_estacion" integer, "p_id_vehiculo" integer, "p_id_conductor" integer, "p_id_combustible" integer, "p_galones" numeric, "p_kilometraje" integer, "p_qrgenerado" "uuid", "p_id_operador" integer, "p_id_estado" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_registrar_abastecimiento"("p_id_cliente" integer, "p_id_estacion" integer, "p_id_vehiculo" integer, "p_id_conductor" integer, "p_id_combustible" integer, "p_galones" numeric, "p_kilometraje" integer, "p_qrgenerado" "uuid", "p_id_operador" integer, "p_id_estado" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_registrar_abastecimiento"("p_id_cliente" integer, "p_id_estacion" integer, "p_id_vehiculo" integer, "p_id_conductor" integer, "p_id_combustible" integer, "p_galones" numeric, "p_kilometraje" integer, "p_qrgenerado" "uuid", "p_id_operador" integer, "p_id_estado" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_saldo_disponible_vehiculo"("p_id_vehiculo" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_saldo_disponible_vehiculo"("p_id_vehiculo" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_saldo_disponible_vehiculo"("p_id_vehiculo" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_set_default_permisos"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_set_default_permisos"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_set_default_permisos"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_max_galones_por_vehiculo"("p_id_vehiculo" integer, "p_id_combustible" integer, "p_id_cliente" integer, "p_id_estacion" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_max_galones_por_vehiculo"("p_id_vehiculo" integer, "p_id_combustible" integer, "p_id_cliente" integer, "p_id_estacion" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_max_galones_por_vehiculo"("p_id_vehiculo" integer, "p_id_combustible" integer, "p_id_cliente" integer, "p_id_estacion" integer) TO "service_role";
























GRANT ALL ON TABLE "public"."auditoria" TO "anon";
GRANT ALL ON TABLE "public"."auditoria" TO "authenticated";
GRANT ALL ON TABLE "public"."auditoria" TO "service_role";



GRANT ALL ON SEQUENCE "public"."auditoria_id_evento_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."auditoria_id_evento_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."auditoria_id_evento_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cb_abastecimientos" TO "anon";
GRANT ALL ON TABLE "public"."cb_abastecimientos" TO "authenticated";
GRANT ALL ON TABLE "public"."cb_abastecimientos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cb_abastecimientos_id_abastecimiento_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cb_abastecimientos_id_abastecimiento_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cb_abastecimientos_id_abastecimiento_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cb_asignaciones_conductor" TO "anon";
GRANT ALL ON TABLE "public"."cb_asignaciones_conductor" TO "authenticated";
GRANT ALL ON TABLE "public"."cb_asignaciones_conductor" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cb_asignaciones_conductor_id_asignacion_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cb_asignaciones_conductor_id_asignacion_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cb_asignaciones_conductor_id_asignacion_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cb_facturacion" TO "anon";
GRANT ALL ON TABLE "public"."cb_facturacion" TO "authenticated";
GRANT ALL ON TABLE "public"."cb_facturacion" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cb_facturacion_id_factura_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cb_facturacion_id_factura_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cb_facturacion_id_factura_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cb_lineas" TO "anon";
GRANT ALL ON TABLE "public"."cb_lineas" TO "authenticated";
GRANT ALL ON TABLE "public"."cb_lineas" TO "service_role";



GRANT ALL ON SEQUENCE "public"."cb_lineas_id_linea_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cb_lineas_id_linea_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cb_lineas_id_linea_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cb_precios_combustible" TO "anon";
GRANT ALL ON TABLE "public"."cb_precios_combustible" TO "authenticated";
GRANT ALL ON TABLE "public"."cb_precios_combustible" TO "service_role";



GRANT SELECT,USAGE ON SEQUENCE "public"."cb_precios_combustible_id_precio_seq" TO "anon";
GRANT SELECT,USAGE ON SEQUENCE "public"."cb_precios_combustible_id_precio_seq" TO "authenticated";
GRANT SELECT,USAGE ON SEQUENCE "public"."cb_precios_combustible_id_precio_seq" TO "service_role";



GRANT ALL ON TABLE "public"."cb_qr_generados" TO "anon";
GRANT ALL ON TABLE "public"."cb_qr_generados" TO "authenticated";
GRANT ALL ON TABLE "public"."cb_qr_generados" TO "service_role";



GRANT ALL ON TABLE "public"."ms_centro_costo" TO "anon";
GRANT ALL ON TABLE "public"."ms_centro_costo" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_centro_costo" TO "service_role";



GRANT SELECT,USAGE ON SEQUENCE "public"."ms_ceentro_costo_id_seq" TO "anon";
GRANT SELECT,USAGE ON SEQUENCE "public"."ms_ceentro_costo_id_seq" TO "authenticated";
GRANT SELECT,USAGE ON SEQUENCE "public"."ms_ceentro_costo_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_clientes" TO "anon";
GRANT ALL ON TABLE "public"."ms_clientes" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_clientes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_clientes_id_cliente_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_clientes_id_cliente_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_clientes_id_cliente_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_combustibles" TO "anon";
GRANT ALL ON TABLE "public"."ms_combustibles" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_combustibles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_combustibles_id_combustible_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_combustibles_id_combustible_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_combustibles_id_combustible_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_conductores" TO "anon";
GRANT ALL ON TABLE "public"."ms_conductores" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_conductores" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_conductores_id_conductor_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_conductores_id_conductor_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_conductores_id_conductor_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_contactos_cliente" TO "anon";
GRANT ALL ON TABLE "public"."ms_contactos_cliente" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_contactos_cliente" TO "service_role";



GRANT ALL ON TABLE "public"."ms_estaciones" TO "anon";
GRANT ALL ON TABLE "public"."ms_estaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_estaciones" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_estaciones_id_estacion_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_estaciones_id_estacion_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_estaciones_id_estacion_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_estados" TO "anon";
GRANT ALL ON TABLE "public"."ms_estados" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_estados" TO "service_role";



GRANT ALL ON TABLE "public"."ms_estados_facturacion" TO "anon";
GRANT ALL ON TABLE "public"."ms_estados_facturacion" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_estados_facturacion" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_estados_facturacion_id_estado_facturacion_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_estados_facturacion_id_estado_facturacion_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_estados_facturacion_id_estado_facturacion_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_estados_id_estado_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_estados_id_estado_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_estados_id_estado_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_feriados" TO "anon";
GRANT ALL ON TABLE "public"."ms_feriados" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_feriados" TO "service_role";



GRANT ALL ON TABLE "public"."ms_operadores_estacion" TO "anon";
GRANT ALL ON TABLE "public"."ms_operadores_estacion" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_operadores_estacion" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_operadores_estacion_id_operador_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_operadores_estacion_id_operador_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_operadores_estacion_id_operador_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_periodos_facturacion" TO "anon";
GRANT ALL ON TABLE "public"."ms_periodos_facturacion" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_periodos_facturacion" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_periodos_facturacion_id_periodo_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_periodos_facturacion_id_periodo_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_periodos_facturacion_id_periodo_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_proveedores" TO "anon";
GRANT ALL ON TABLE "public"."ms_proveedores" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_proveedores" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_proveedores_id_proveedor_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_proveedores_id_proveedor_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_proveedores_id_proveedor_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_roles" TO "anon";
GRANT ALL ON TABLE "public"."ms_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_roles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_roles_id_rol_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_roles_id_rol_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_roles_id_rol_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_tipos_estacion" TO "anon";
GRANT ALL ON TABLE "public"."ms_tipos_estacion" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_tipos_estacion" TO "service_role";



GRANT SELECT,USAGE ON SEQUENCE "public"."ms_tipos_estacion_id_tipo_estacion_seq" TO "anon";
GRANT SELECT,USAGE ON SEQUENCE "public"."ms_tipos_estacion_id_tipo_estacion_seq" TO "authenticated";
GRANT SELECT,USAGE ON SEQUENCE "public"."ms_tipos_estacion_id_tipo_estacion_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_tipos_linea_credito" TO "anon";
GRANT ALL ON TABLE "public"."ms_tipos_linea_credito" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_tipos_linea_credito" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_tipos_linea_credito_id_tipo_linea_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_tipos_linea_credito_id_tipo_linea_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_tipos_linea_credito_id_tipo_linea_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_usuarios" TO "anon";
GRANT ALL ON TABLE "public"."ms_usuarios" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_usuarios" TO "service_role";



GRANT ALL ON TABLE "public"."ms_vehiculos" TO "anon";
GRANT ALL ON TABLE "public"."ms_vehiculos" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_vehiculos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_vehiculos_id_vehiculo_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_vehiculos_id_vehiculo_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_vehiculos_id_vehiculo_seq" TO "service_role";



GRANT ALL ON TABLE "public"."ms_zonas" TO "anon";
GRANT ALL ON TABLE "public"."ms_zonas" TO "authenticated";
GRANT ALL ON TABLE "public"."ms_zonas" TO "service_role";



GRANT ALL ON SEQUENCE "public"."ms_zonas_id_zona_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ms_zonas_id_zona_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ms_zonas_id_zona_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pagos" TO "anon";
GRANT ALL ON TABLE "public"."pagos" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pagos_id_pago_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pagos_id_pago_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pagos_id_pago_seq" TO "service_role";



GRANT ALL ON TABLE "public"."rl_proveedor_estacion" TO "anon";
GRANT ALL ON TABLE "public"."rl_proveedor_estacion" TO "authenticated";
GRANT ALL ON TABLE "public"."rl_proveedor_estacion" TO "service_role";



GRANT ALL ON TABLE "public"."rl_vehiculo_combustible" TO "anon";
GRANT ALL ON TABLE "public"."rl_vehiculo_combustible" TO "authenticated";
GRANT ALL ON TABLE "public"."rl_vehiculo_combustible" TO "service_role";



GRANT ALL ON TABLE "public"."vw_abastecimientos_diarios_30d" TO "anon";
GRANT ALL ON TABLE "public"."vw_abastecimientos_diarios_30d" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_abastecimientos_diarios_30d" TO "service_role";



GRANT ALL ON TABLE "public"."vw_abastecimientos_diarios_15d_arrays" TO "anon";
GRANT ALL ON TABLE "public"."vw_abastecimientos_diarios_15d_arrays" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_abastecimientos_diarios_15d_arrays" TO "service_role";



GRANT ALL ON TABLE "public"."vw_abastecimientos_no_facturados" TO "anon";
GRANT ALL ON TABLE "public"."vw_abastecimientos_no_facturados" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_abastecimientos_no_facturados" TO "service_role";



GRANT ALL ON TABLE "public"."vw_abastecimientos_ultimos_movimientos" TO "anon";
GRANT ALL ON TABLE "public"."vw_abastecimientos_ultimos_movimientos" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_abastecimientos_ultimos_movimientos" TO "service_role";



GRANT ALL ON TABLE "public"."vw_admin_abastecimientos" TO "anon";
GRANT ALL ON TABLE "public"."vw_admin_abastecimientos" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_admin_abastecimientos" TO "service_role";



GRANT ALL ON TABLE "public"."vw_admin_abastecimientos_kpi_mensual" TO "anon";
GRANT ALL ON TABLE "public"."vw_admin_abastecimientos_kpi_mensual" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_admin_abastecimientos_kpi_mensual" TO "service_role";



GRANT ALL ON TABLE "public"."vw_asignaciones_conductor" TO "anon";
GRANT ALL ON TABLE "public"."vw_asignaciones_conductor" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_asignaciones_conductor" TO "service_role";



GRANT ALL ON TABLE "public"."vw_centro_costo_estado" TO "anon";
GRANT ALL ON TABLE "public"."vw_centro_costo_estado" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_centro_costo_estado" TO "service_role";



GRANT ALL ON TABLE "public"."vw_cliente_contacto_principal" TO "anon";
GRANT ALL ON TABLE "public"."vw_cliente_contacto_principal" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_cliente_contacto_principal" TO "service_role";



GRANT ALL ON TABLE "public"."vw_clientes_con_cantidad_vehiculos" TO "anon";
GRANT ALL ON TABLE "public"."vw_clientes_con_cantidad_vehiculos" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_clientes_con_cantidad_vehiculos" TO "service_role";



GRANT ALL ON TABLE "public"."vw_clientes_zonas_estaciones" TO "anon";
GRANT ALL ON TABLE "public"."vw_clientes_zonas_estaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_clientes_zonas_estaciones" TO "service_role";



GRANT ALL ON TABLE "public"."vw_combustibles_cliente" TO "anon";
GRANT ALL ON TABLE "public"."vw_combustibles_cliente" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_combustibles_cliente" TO "service_role";



GRANT ALL ON TABLE "public"."vw_combustibles_dropdown" TO "anon";
GRANT ALL ON TABLE "public"."vw_combustibles_dropdown" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_combustibles_dropdown" TO "service_role";



GRANT ALL ON TABLE "public"."vw_conductores_sin_vehiculo" TO "anon";
GRANT ALL ON TABLE "public"."vw_conductores_sin_vehiculo" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_conductores_sin_vehiculo" TO "service_role";



GRANT ALL ON TABLE "public"."vw_consumo_galones_por_combustible_mes_actual_arrays" TO "anon";
GRANT ALL ON TABLE "public"."vw_consumo_galones_por_combustible_mes_actual_arrays" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_consumo_galones_por_combustible_mes_actual_arrays" TO "service_role";



GRANT ALL ON TABLE "public"."vw_consumo_galones_por_estacion_mes_actual_arrays" TO "anon";
GRANT ALL ON TABLE "public"."vw_consumo_galones_por_estacion_mes_actual_arrays" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_consumo_galones_por_estacion_mes_actual_arrays" TO "service_role";



GRANT ALL ON TABLE "public"."vw_consumo_galones_por_zona_mes_actual_arrays" TO "anon";
GRANT ALL ON TABLE "public"."vw_consumo_galones_por_zona_mes_actual_arrays" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_consumo_galones_por_zona_mes_actual_arrays" TO "service_role";



GRANT ALL ON TABLE "public"."vw_dashboard_admin_kpis_mes_actual" TO "anon";
GRANT ALL ON TABLE "public"."vw_dashboard_admin_kpis_mes_actual" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_dashboard_admin_kpis_mes_actual" TO "service_role";



GRANT ALL ON TABLE "public"."vw_estaciones_cliente_combustible" TO "anon";
GRANT ALL ON TABLE "public"."vw_estaciones_cliente_combustible" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_estaciones_cliente_combustible" TO "service_role";



GRANT ALL ON TABLE "public"."vw_estaciones_con_zona" TO "anon";
GRANT ALL ON TABLE "public"."vw_estaciones_con_zona" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_estaciones_con_zona" TO "service_role";



GRANT ALL ON TABLE "public"."vw_estaciones_dropdown" TO "anon";
GRANT ALL ON TABLE "public"."vw_estaciones_dropdown" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_estaciones_dropdown" TO "service_role";



GRANT ALL ON TABLE "public"."vw_facturacion_abastecimientos_resumen" TO "anon";
GRANT ALL ON TABLE "public"."vw_facturacion_abastecimientos_resumen" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_facturacion_abastecimientos_resumen" TO "service_role";



GRANT ALL ON TABLE "public"."vw_historial_abastecimientos" TO "anon";
GRANT ALL ON TABLE "public"."vw_historial_abastecimientos" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_historial_abastecimientos" TO "service_role";



GRANT ALL ON TABLE "public"."vw_historial_precios_por_zona" TO "anon";
GRANT ALL ON TABLE "public"."vw_historial_precios_por_zona" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_historial_precios_por_zona" TO "service_role";



GRANT ALL ON TABLE "public"."vw_kpi_abastecimientos" TO "anon";
GRANT ALL ON TABLE "public"."vw_kpi_abastecimientos" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_kpi_abastecimientos" TO "service_role";



GRANT ALL ON TABLE "public"."vw_kpi_galones_mes_actual" TO "anon";
GRANT ALL ON TABLE "public"."vw_kpi_galones_mes_actual" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_kpi_galones_mes_actual" TO "service_role";



GRANT ALL ON TABLE "public"."vw_kpi_lineas_credito" TO "anon";
GRANT ALL ON TABLE "public"."vw_kpi_lineas_credito" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_kpi_lineas_credito" TO "service_role";



GRANT ALL ON TABLE "public"."vw_kpi_reporteglobal" TO "anon";
GRANT ALL ON TABLE "public"."vw_kpi_reporteglobal" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_kpi_reporteglobal" TO "service_role";



GRANT ALL ON TABLE "public"."vw_lineas_credito_listado" TO "anon";
GRANT ALL ON TABLE "public"."vw_lineas_credito_listado" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_lineas_credito_listado" TO "service_role";



GRANT ALL ON TABLE "public"."vw_movimientos_abastecimientos_simple" TO "anon";
GRANT ALL ON TABLE "public"."vw_movimientos_abastecimientos_simple" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_movimientos_abastecimientos_simple" TO "service_role";



GRANT ALL ON TABLE "public"."vw_ms_centro_costo_con_default" TO "anon";
GRANT ALL ON TABLE "public"."vw_ms_centro_costo_con_default" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_ms_centro_costo_con_default" TO "service_role";



GRANT ALL ON TABLE "public"."vw_ms_vehiculos_con_centro" TO "anon";
GRANT ALL ON TABLE "public"."vw_ms_vehiculos_con_centro" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_ms_vehiculos_con_centro" TO "service_role";



GRANT ALL ON TABLE "public"."vw_operadores_estacion" TO "anon";
GRANT ALL ON TABLE "public"."vw_operadores_estacion" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_operadores_estacion" TO "service_role";



GRANT ALL ON TABLE "public"."vw_pagos_abastecimientos_resumen" TO "anon";
GRANT ALL ON TABLE "public"."vw_pagos_abastecimientos_resumen" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_pagos_abastecimientos_resumen" TO "service_role";



GRANT ALL ON TABLE "public"."vw_precios_combustible_cliente" TO "anon";
GRANT ALL ON TABLE "public"."vw_precios_combustible_cliente" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_precios_combustible_cliente" TO "service_role";



GRANT ALL ON TABLE "public"."vw_precios_vigentes_por_zona" TO "anon";
GRANT ALL ON TABLE "public"."vw_precios_vigentes_por_zona" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_precios_vigentes_por_zona" TO "service_role";



GRANT ALL ON TABLE "public"."vw_qr_generados_detalle" TO "anon";
GRANT ALL ON TABLE "public"."vw_qr_generados_detalle" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_qr_generados_detalle" TO "service_role";



GRANT ALL ON TABLE "public"."vw_reporte_estacion" TO "anon";
GRANT ALL ON TABLE "public"."vw_reporte_estacion" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_reporte_estacion" TO "service_role";



GRANT ALL ON TABLE "public"."vw_reporte_vehiculo" TO "anon";
GRANT ALL ON TABLE "public"."vw_reporte_vehiculo" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_reporte_vehiculo" TO "service_role";



GRANT ALL ON TABLE "public"."vw_reporteglobal_abastecimientos" TO "anon";
GRANT ALL ON TABLE "public"."vw_reporteglobal_abastecimientos" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_reporteglobal_abastecimientos" TO "service_role";



GRANT ALL ON TABLE "public"."vw_tipos_estacion_conteo" TO "anon";
GRANT ALL ON TABLE "public"."vw_tipos_estacion_conteo" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_tipos_estacion_conteo" TO "service_role";



GRANT ALL ON TABLE "public"."vw_total_estaciones_por_zona_arrays" TO "anon";
GRANT ALL ON TABLE "public"."vw_total_estaciones_por_zona_arrays" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_total_estaciones_por_zona_arrays" TO "service_role";



GRANT ALL ON TABLE "public"."vw_usuario_permisos_json" TO "anon";
GRANT ALL ON TABLE "public"."vw_usuario_permisos_json" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_usuario_permisos_json" TO "service_role";



GRANT ALL ON TABLE "public"."vw_usuarios_permisos_resumen" TO "anon";
GRANT ALL ON TABLE "public"."vw_usuarios_permisos_resumen" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_usuarios_permisos_resumen" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculo_combustible" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculo_combustible" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculo_combustible" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculo_combustible_dropdown" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculo_combustible_dropdown" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculo_combustible_dropdown" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculos_ccosto" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculos_ccosto" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculos_ccosto" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculos_con_combustibles" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculos_con_combustibles" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculos_con_combustibles" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculos_conductores_asignaciones" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculos_conductores_asignaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculos_conductores_asignaciones" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculos_conductores_cliente" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculos_conductores_cliente" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculos_conductores_cliente" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculos_consumo_resumen" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculos_consumo_resumen" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculos_consumo_resumen" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculos_estado" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculos_estado" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculos_estado" TO "service_role";



GRANT ALL ON TABLE "public"."vw_vehiculos_sin_asignar" TO "anon";
GRANT ALL ON TABLE "public"."vw_vehiculos_sin_asignar" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_vehiculos_sin_asignar" TO "service_role";



GRANT ALL ON TABLE "public"."vw_zonas_con_estaciones" TO "anon";
GRANT ALL ON TABLE "public"."vw_zonas_con_estaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."vw_zonas_con_estaciones" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";




























