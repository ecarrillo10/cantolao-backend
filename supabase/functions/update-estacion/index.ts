import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  // =====================================================
  // CORS (PATRÓN ESTABLE)
  // =====================================================
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type"
  };
  // Preflight
  if (req.method === "OPTIONS") {
    return new Response(JSON.stringify({
      ok: true
    }), {
      status: 200,
      headers
    });
  }
  try {
    // =====================================================
    // SOLO POST
    // =====================================================
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
    ===================================================== */ const { uid_usuario, id_estacion, nombre, ubicacion, id_tipo_estacion, latitud, longitud, id_zona } = await req.json();
    if (!uid_usuario || !id_estacion || !nombre || !ubicacion || !id_tipo_estacion || !id_zona) {
      return new Response(JSON.stringify({
        error: "Completa todos los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       2️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       3️⃣ OBTENER ESTACIÓN ACTUAL (data_before)
    ===================================================== */ const { data: estacionActual } = await supabase.from("ms_estaciones").select("*").eq("id_estacion", id_estacion).maybeSingle();
    if (!estacionActual) {
      return new Response(JSON.stringify({
        error: "La estación que intentas editar no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       4️⃣ VALIDAR ZONA
    ===================================================== */ const { data: zona } = await supabase.from("ms_zonas").select("id_zona").eq("id_zona", id_zona).maybeSingle();
    if (!zona) {
      return new Response(JSON.stringify({
        error: "La zona seleccionada no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       5️⃣ VALIDAR TIPO DE ESTACIÓN
    ===================================================== */ const { data: tipo } = await supabase.from("ms_tipos_estacion").select("id_tipo_estacion").eq("id_tipo_estacion", id_tipo_estacion).maybeSingle();
    if (!tipo) {
      return new Response(JSON.stringify({
        error: "El tipo de estación seleccionado no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       6️⃣ ACTUALIZAR ESTACIÓN
    ===================================================== */ const { error: updateError } = await supabase.from("ms_estaciones").update({
      nombre,
      ubicacion,
      id_tipo_estacion,
      latitud,
      longitud,
      id_zona
    }).eq("id_estacion", id_estacion);
    if (updateError) {
      console.error(updateError);
      return new Response(JSON.stringify({
        error: "Ocurrió un error al actualizar la estación."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       7️⃣ AUDITORÍA
    ===================================================== */ const dataAfter = {
      ...estacionActual,
      nombre,
      ubicacion,
      id_tipo_estacion,
      latitud,
      longitud,
      id_zona
    };
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_estaciones",
      accion: "UPDATE_ESTACION",
      registro_id: String(id_estacion),
      data_before: estacionActual,
      data_after: dataAfter
    });
    /* =====================================================
       8️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "La información de la estación se actualizó correctamente."
    }), {
      status: 200,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "Ocurrió un error inesperado. Inténtalo más tarde."
    }), {
      status: 500,
      headers
    });
  }
});
