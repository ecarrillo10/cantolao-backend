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
    ===================================================== */ const { uid_usuario, id_asignacion, fecha_inicio, fecha_fin } = await req.json();
    if (!uid_usuario || !id_asignacion || !fecha_inicio) {
      return new Response(JSON.stringify({
        error: "Campos obligatorios incompletos."
      }), {
        status: 400,
        headers
      });
    }
    const fechaFinFinal = fecha_fin && fecha_fin !== "" && fecha_fin !== "null" ? fecha_fin : null;
    /* =====================================================
       2️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       3️⃣ OBTENER ASIGNACIÓN ACTUAL (BEFORE)
    ===================================================== */ const { data: asignacionActual } = await supabase.from("cb_asignaciones_conductor").select("*").eq("id_asignacion", id_asignacion).maybeSingle();
    if (!asignacionActual) {
      return new Response(JSON.stringify({
        error: "La asignación no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       4️⃣ UPDATE
    ===================================================== */ const { error: updateError } = await supabase.from("cb_asignaciones_conductor").update({
      fecha_inicio,
      fecha_fin: fechaFinFinal
    }).eq("id_asignacion", id_asignacion);
    if (updateError) {
      return new Response(JSON.stringify({
        error: "No se pudo actualizar la asignación.",
        detalle: updateError.message
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       5️⃣ OBTENER ASIGNACIÓN AFTER
    ===================================================== */ const { data: asignacionAfter } = await supabase.from("cb_asignaciones_conductor").select("*").eq("id_asignacion", id_asignacion).single();
    /* =====================================================
       📘 AUDITORÍA
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "cb_asignaciones_conductor",
      accion: "UPDATE_ASIGNACION_CONDUCTOR",
      registro_id: String(id_asignacion),
      data_before: asignacionActual,
      data_after: asignacionAfter
    });
    /* =====================================================
       6️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Asignación actualizada correctamente."
    }), {
      status: 200,
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
