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
        error: "Método no permitido"
      }), {
        status: 405,
        headers
      });
    }
    /* =====================================================
       2️⃣ LEER BODY
    ===================================================== */ const { uid_usuario, nombre, ubicacion, id_tipo_estacion, latitud, longitud, id_zona } = await req.json();
    if (!uid_usuario || !nombre || !ubicacion || !id_tipo_estacion || !id_zona) {
      return new Response(JSON.stringify({
        error: "Completa todos los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       3️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       4️⃣ VALIDAR ZONA EXISTE
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
       5️⃣ VALIDAR TIPO DE ESTACIÓN EXISTE
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
       6️⃣ INSERTAR ESTACIÓN (y devolver el id_estacion)
    ===================================================== */ const { data: inserted, error: insertError } = await supabase.from("ms_estaciones").insert({
      nombre,
      ubicacion,
      id_tipo_estacion,
      latitud,
      longitud,
      id_zona,
      estado: true
    }).select("id_estacion, nombre, ubicacion, id_tipo_estacion, latitud, longitud, id_zona, estado").maybeSingle();
    if (insertError || !inserted) {
      console.error(insertError);
      return new Response(JSON.stringify({
        error: "No se pudo registrar la estación. Inténtalo más tarde."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       ✅ AUDITORÍA (INSERT)
       - registro_id: PK real (id_estacion)
       - data_before: null
       - data_after : registro creado
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_estaciones",
      accion: "INSERT_ESTACION",
      registro_id: String(inserted.id_estacion),
      data_before: null,
      data_after: inserted
    });
    /* =====================================================
       7️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Estación registrada correctamente."
    }), {
      status: 201,
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
