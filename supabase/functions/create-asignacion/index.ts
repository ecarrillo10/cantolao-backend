import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type"
  };
  if (req.method === "OPTIONS") {
    return new Response(JSON.stringify({
      ok: true
    }), {
      status: 200,
      headers
    });
  }
  try {
    if (req.method !== "POST") {
      return new Response(JSON.stringify({
        error: "Método no permitido."
      }), {
        status: 405,
        headers
      });
    }
    /* =====================================================
       1️⃣ BODY
    ===================================================== */ const { uid_usuario, id_conductor, id_vehiculo, fecha_inicio, fecha_fin } = await req.json();
    if (!uid_usuario || !id_conductor || !id_vehiculo || !fecha_inicio) {
      return new Response(JSON.stringify({
        error: "Campos obligatorios incompletos."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       2️⃣ NORMALIZAR FECHA FIN
    ===================================================== */ const fechaFinFinal = fecha_fin && fecha_fin !== "" && fecha_fin !== "null" ? fecha_fin : null;
    /* =====================================================
       3️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       4️⃣ VALIDAR VEHÍCULO ACTIVO
    ===================================================== */ const { data: vehiculo } = await supabase.from("ms_vehiculos").select("id_vehiculo, estado").eq("id_vehiculo", id_vehiculo).maybeSingle();
    if (!vehiculo || vehiculo.estado === false) {
      return new Response(JSON.stringify({
        error: "El vehículo no existe o está inactivo."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       5️⃣ VALIDAR CONDUCTOR ACTIVO
    ===================================================== */ const { data: conductor } = await supabase.from("ms_conductores").select("id_conductor, estado").eq("id_conductor", id_conductor).maybeSingle();
    if (!conductor || conductor.estado === false) {
      return new Response(JSON.stringify({
        error: "El conductor no existe o está inactivo."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       6️⃣ VALIDAR NO DUPLICAR ASIGNACIÓN ACTIVA
    ===================================================== */ const { data: asignacionActiva } = await supabase.from("cb_asignaciones_conductor").select("id_asignacion").eq("id_vehiculo", id_vehiculo).eq("id_conductor", id_conductor).eq("estado", true).maybeSingle();
    if (asignacionActiva) {
      return new Response(JSON.stringify({
        error: "Este conductor ya tiene una asignación activa con este vehículo."
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       7️⃣ INSERTAR ASIGNACIÓN
    ===================================================== */ const { data: asignacion, error } = await supabase.from("cb_asignaciones_conductor").insert({
      id_conductor,
      id_vehiculo,
      fecha_inicio,
      fecha_fin: fechaFinFinal,
      estado: true
    }).select().single();
    if (error) {
      return new Response(JSON.stringify({
        error: "No se pudo registrar la asignación.",
        detalle: error.message
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       📘 AUDITORÍA
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "cb_asignaciones_conductor",
      accion: "CREATE_ASIGNACION_CONDUCTOR",
      registro_id: String(asignacion.id_asignacion),
      data_before: null,
      data_after: asignacion
    });
    /* =====================================================
       8️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Asignación creada correctamente.",
      asignacion
    }), {
      status: 201,
      headers
    });
  } catch (err) {
    return new Response(JSON.stringify({
      error: "Error inesperado.",
      detalle: err?.message ?? err
    }), {
      status: 500,
      headers
    });
  }
});
