// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const json = (body, status = 200)=>new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS"
    }
  });
const fail = (code, message)=>json({
    valid: false,
    code,
    message
  });
function toNum(n) {
  if (typeof n === "number") return n;
  if (typeof n === "string" && n.trim() !== "" && !Number.isNaN(Number(n))) {
    return Number(n);
  }
  return NaN;
}
const nowIso = ()=>new Date().toISOString();
const todayYmd = ()=>new Date().toISOString().slice(0, 10);
serve(async (req)=>{
  if (req.method === "OPTIONS") return json({
    ok: true
  });
  if (req.method !== "POST") {
    return json({
      valid: false,
      code: "METHOD_NOT_ALLOWED",
      message: "Método no permitido"
    }, 405);
  }
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return json({
      valid: false,
      code: "CONFIG_ERROR",
      message: "Faltan variables de entorno en la función"
    }, 500);
  }
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: {
      headers: {
        Authorization: authHeader
      }
    }
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return fail("UNAUTHORIZED", "Sesión no válida. Inicia sesión nuevamente.");
  }
  const id_usuario = userData.user.id;
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  let body;
  try {
    body = await req.json();
  } catch  {
    return json({
      valid: false,
      code: "BAD_JSON",
      message: "Body inválido (JSON)"
    }, 400);
  }
  const required = [
    "id_cliente",
    "id_vehiculo",
    "id_conductor",
    "id_estacion",
    "id_combustible",
    "galones",
    "kilometraje"
  ];
  for (const k of required){
    if (body?.[k] === undefined || body?.[k] === null || body?.[k] === "") {
      return fail("MISSING_FIELDS", "Faltan campos obligatorios para validar el abastecimiento.");
    }
  }
  const id_cliente = toNum(body.id_cliente);
  const id_vehiculo = toNum(body.id_vehiculo);
  const id_conductor = toNum(body.id_conductor);
  const id_estacion = toNum(body.id_estacion);
  const id_combustible = toNum(body.id_combustible);
  const galones = toNum(body.galones);
  const kilometraje = toNum(body.kilometraje);
  if (![
    id_cliente,
    id_vehiculo,
    id_conductor,
    id_estacion,
    id_combustible,
    galones,
    kilometraje
  ].every((x)=>Number.isFinite(x))) {
    return fail("INVALID_TYPES", "Revisa los datos enviados (números/formatos).");
  }
  if (galones <= 0) return fail("INVALID_GALONES", "Los galones deben ser mayor a 0.");
  if (kilometraje < 0) return fail("INVALID_KM", "Kilometraje inválido.");
  const { data: cliente, error: eCli } = await admin.from("ms_clientes").select("id_cliente, estado").eq("id_cliente", id_cliente).maybeSingle();
  if (eCli) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando cliente."
    }, 500);
  }
  if (!cliente) return fail("CLIENT_NOT_FOUND", "Cliente no existe.");
  if (cliente.estado !== true) return fail("CLIENT_INACTIVE", "Cliente inactivo.");
  const { data: vehiculo, error: eVeh } = await admin.from("ms_vehiculos").select("id_vehiculo, id_cliente, estado, id_centro_costo, monto_asignado").eq("id_vehiculo", id_vehiculo).maybeSingle();
  if (eVeh) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando vehículo."
    }, 500);
  }
  if (!vehiculo) return fail("VEHICLE_NOT_FOUND", "Vehículo no existe.");
  if (vehiculo.estado !== true) return fail("VEHICLE_INACTIVE", "Vehículo inactivo.");
  if (vehiculo.id_cliente !== id_cliente) {
    return fail("VEHICLE_NOT_OWNED", "El vehículo no pertenece al cliente.");
  }
  const { data: conductor, error: eCon } = await admin.from("ms_conductores").select("id_conductor, id_cliente, estado").eq("id_conductor", id_conductor).maybeSingle();
  if (eCon) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando conductor."
    }, 500);
  }
  if (!conductor) return fail("DRIVER_NOT_FOUND", "Conductor no existe.");
  if (conductor.estado !== true) return fail("DRIVER_INACTIVE", "Conductor inactivo.");
  if (conductor.id_cliente !== id_cliente) {
    return fail("DRIVER_NOT_OWNED", "El conductor no pertenece al cliente.");
  }
  const { data: asigns, error: eAsg } = await admin.from("cb_asignaciones_conductor").select("id_asignacion, fecha_inicio, fecha_fin").eq("id_vehiculo", id_vehiculo).eq("id_conductor", id_conductor).order("fecha_inicio", {
    ascending: false
  }).limit(20);
  if (eAsg) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando asignación del conductor."
    }, 500);
  }
  const today = todayYmd();
  const inRange = (fi, ff)=>{
    if (fi && fi > today) return false;
    if (ff && ff < today) return false;
    return true;
  };
  const hasAsignacionVigente = (asigns ?? []).some((a)=>inRange(a.fecha_inicio ?? null, a.fecha_fin ?? null));
  if (!hasAsignacionVigente) {
    return fail("DRIVER_NOT_ASSIGNED", "El conductor no está asignado al vehículo.");
  }
  const { data: estacion, error: eEst } = await admin.from("ms_estaciones").select("id_estacion, estado").eq("id_estacion", id_estacion).maybeSingle();
  if (eEst) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando estación."
    }, 500);
  }
  if (!estacion) return fail("STATION_NOT_FOUND", "Estación no existe.");
  if (estacion.estado !== true) return fail("STATION_INACTIVE", "Estación inactiva.");
  const { data: vc, error: eVC } = await admin.from("rl_vehiculo_combustible").select("id_vehiculo, id_combustible").eq("id_vehiculo", id_vehiculo).eq("id_combustible", id_combustible).maybeSingle();
  if (eVC) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando combustible del vehículo."
    }, 500);
  }
  if (!vc) {
    return fail("FUEL_NOT_ALLOWED", "Este vehículo no tiene permitido ese combustible.");
  }
  const { data: operador, error: eOp } = await admin.from("ms_operadores_estacion").select("id_operador, activo").eq("id_usuario", id_usuario).eq("id_estacion", id_estacion).maybeSingle();
  if (eOp) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando operador."
    }, 500);
  }
  if (!operador) {
    return fail("OPERATOR_NOT_ASSIGNED", "Operador no autorizado en esta estación.");
  }
  if (operador.activo !== true) return fail("OPERATOR_INACTIVE", "Operador inactivo.");
  const now = nowIso();
  const { data: precios, error: ePre } = await admin.from("cb_precios_combustible").select("precio, fecha_inicio, fecha_fin, estado").eq("id_cliente", id_cliente).eq("id_estacion", id_estacion).eq("id_combustible", id_combustible).eq("estado", true).lte("fecha_inicio", now).order("fecha_inicio", {
    ascending: false
  }).limit(10);
  if (ePre) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando precio."
    }, 500);
  }
  const vigente = (precios ?? []).find((p)=>!p.fecha_fin || new Date(p.fecha_fin).getTime() >= Date.now());
  if (!vigente || vigente.precio === null || vigente.precio === undefined) {
    return fail("PRICE_NOT_FOUND", "No existe precio vigente para este cliente, estación y combustible.");
  }
  const precio = Number(vigente.precio);
  if (!Number.isFinite(precio) || precio <= 0) {
    return fail("PRICE_INVALID", "Precio inválido en el sistema.");
  }
  const total = Number((galones * precio).toFixed(2));
  const { data: linea, error: eLin } = await admin.from("vw_lineas_credito_listado").select("id_linea, estado, fecha_creacion").eq("id_cliente", id_cliente).eq("estado", true).order("fecha_creacion", {
    ascending: false
  }).order("id_linea", {
    ascending: false
  }).limit(1).maybeSingle();
  if (eLin) {
    return json({
      valid: false,
      code: "DB_ERROR",
      message: "Error validando línea de crédito."
    }, 500);
  }
  if (!linea) {
    return fail("LINE_NOT_FOUND", "El cliente no tiene una línea de crédito activa.");
  }
  const { data: saldoFn, error: eSaldo } = await admin.rpc("fn_saldo_disponible_vehiculo", {
    p_id_vehiculo: id_vehiculo
  });
  if (eSaldo) {
    return fail("SALDO_ERROR", "No se pudo calcular el saldo disponible para el vehículo.");
  }
  const saldoDisponible = Number(saldoFn ?? NaN);
  if (!Number.isFinite(saldoDisponible)) {
    return fail("SALDO_ERROR", "Saldo disponible inválido.");
  }
  let fuenteSaldo = "LINEA";
  if (vehiculo.monto_asignado !== null && vehiculo.monto_asignado !== undefined) {
    fuenteSaldo = "VEHICULO";
  } else if (vehiculo.id_centro_costo !== null && vehiculo.id_centro_costo !== undefined) {
    fuenteSaldo = "CENTRO_COSTO";
  }
  if (saldoDisponible < 0) {
    return fail("NEGATIVE_BALANCE", "No se permite saldo negativo.");
  }
  // ================================
  // VALIDAR GALONES MÁXIMOS (sin cambiar response)
  // ================================
  const round3 = (n)=>Math.round(n * 1000) / 1000;
  const galonesMaximos = saldoDisponible <= 0 ? 0 : round3(saldoDisponible / precio);
  // margen por redondeo (total se redondea a 2 decimales)
  const EPS = 0.005;
  if (galones > galonesMaximos + EPS) {
    return fail("MAX_GALONES_EXCEEDED", `Los galones solicitados (${galones}) exceden el máximo permitido (${galonesMaximos}) según el saldo disponible.`);
  }
  // (si quieres mantener esta validación también)
  if (total > saldoDisponible) {
    return fail("INSUFFICIENT_FUNDS", "Saldo insuficiente para este abastecimiento.");
  }
  const ok = {
    valid: true,
    code: "OK",
    message: "Validación OK. Puedes confirmar el abastecimiento.",
    data: {
      precio,
      total_estimado: total,
      saldo_disponible: Number(saldoDisponible.toFixed(2)),
      fuente_saldo: fuenteSaldo,
      id_operador: operador.id_operador,
      id_linea: linea.id_linea ?? undefined,
      id_centro_costo: vehiculo.id_centro_costo ?? null
    }
  };
  return json(ok);
});
