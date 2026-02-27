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
function isUuid(v) {
  if (typeof v !== "string") return false;
  return /^[0-9a-f-]{36}$/i.test(v);
}
serve(async (req)=>{
  // =====================================================
  // CORS
  // =====================================================
  if (req.method === "OPTIONS") return json({
    ok: true
  });
  if (req.method !== "POST") {
    return json({
      valid: false,
      code: "METHOD_NOT_ALLOWED",
      message: "Este servicio solo acepta solicitudes POST."
    }, 405);
  }
  // =====================================================
  // ENV
  // =====================================================
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return json({
      valid: false,
      code: "CONFIG_ERROR",
      message: "La función no está configurada correctamente. Contacta al administrador."
    }, 500);
  }
  // =====================================================
  // AUTH USUARIO (OPERADOR)
  // =====================================================
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: {
      headers: {
        Authorization: authHeader
      }
    }
  });
  const { data: userData } = await userClient.auth.getUser();
  if (!userData?.user) {
    return fail("UNAUTHORIZED", "Tu sesión ha expirado. Por favor vuelve a iniciar sesión.");
  }
  const id_usuario = userData.user.id;
  // =====================================================
  // ADMIN CLIENT
  // =====================================================
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  // =====================================================
  // BODY
  // =====================================================
  let body;
  try {
    body = await req.json();
  } catch  {
    return fail("BAD_JSON", "Los datos enviados no tienen un formato válido.");
  }
  const required = [
    "id_qr",
    "id_vehiculo",
    "id_conductor",
    "id_estacion",
    "id_combustible"
  ];
  for (const k of required){
    if (!body?.[k]) {
      return fail("MISSING_FIELDS", "Faltan datos obligatorios para validar el QR.");
    }
  }
  const id_qr = body.id_qr;
  const id_vehiculo = toNum(body.id_vehiculo);
  const id_conductor = toNum(body.id_conductor);
  const id_estacion = toNum(body.id_estacion);
  const id_combustible = toNum(body.id_combustible);
  if (!isUuid(id_qr)) {
    return fail("INVALID_QR", "El código QR no tiene un formato válido.");
  }
  // =====================================================
  // OPERADOR → ESTACIÓN
  // =====================================================
  const { data: operador } = await admin.from("ms_operadores_estacion").select("id_operador, activo").eq("id_usuario", id_usuario).eq("id_estacion", id_estacion).maybeSingle();
  if (!operador) {
    return fail("OPERATOR_NOT_ASSIGNED", "No estás autorizado para operar en esta estación.");
  }
  if (!operador.activo) {
    return fail("OPERATOR_INACTIVE", "Tu usuario de operador está inactivo. Contacta al administrador.");
  }
  // =====================================================
  // QR
  // =====================================================
  const { data: qr } = await admin.from("cb_qr_generados").select("id_qr,id_estado,fecha_expiracion,id_conductor,id_vehiculo,id_estacion,id_combustible").eq("id_qr", id_qr).maybeSingle();
  if (!qr) {
    return fail("QR_NOT_FOUND", "El QR no existe o no fue generado por el sistema.");
  }
  const estado = Number(qr.id_estado);
  if (estado === 2) return fail("QR_USED", "Este QR ya fue utilizado.");
  if (estado === 3) return fail("QR_EXPIRED", "Este QR ya venció.");
  if (estado === 4) return fail("QR_DISPATCHED", "Este QR ya fue despachado.");
  if (estado === 5) return fail("QR_CANCELLED", "Este QR fue cancelado.");
  if (estado === 6) return fail("QR_ADMIN", "Este QR administrativo no puede usarse aquí.");
  if (estado === 7) return fail("QR_SCANNED", "Este QR ya fue escaneado previamente.");
  if (estado !== 1) {
    return fail("QR_INVALID", "El QR no se encuentra en un estado válido para usar.");
  }
  // =====================================================
  // MATCH
  // =====================================================
  if (qr.id_vehiculo !== id_vehiculo) {
    return fail("QR_MISMATCH", "El QR no corresponde al vehículo seleccionado.");
  }
  if (qr.id_conductor !== id_conductor) {
    return fail("QR_MISMATCH", "El QR no corresponde al conductor seleccionado.");
  }
  if (qr.id_combustible !== id_combustible) {
    return fail("QR_MISMATCH", "El QR no corresponde al tipo de combustible.");
  }
  // =====================================================
  // FECHA EXPIRACIÓN
  // =====================================================
  if (qr.fecha_expiracion) {
    const exp = new Date(qr.fecha_expiracion).getTime();
    if (Date.now() > exp) {
      return fail("QR_EXPIRED", "Este QR ya venció por fecha de expiración.");
    }
  }
  // =====================================================
  // OK
  // =====================================================
  return json({
    valid: true,
    code: "OK",
    message: "QR válido. Puedes continuar con el abastecimiento.",
    data: {
      id_operador: operador.id_operador
    }
  });
});
