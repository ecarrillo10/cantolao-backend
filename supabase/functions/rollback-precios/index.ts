import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  /* =====================================================
     CORS
  ===================================================== */ const headers = {
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
       BODY
    ===================================================== */ const { uid_usuario, version_id } = await req.json();
    if (!uid_usuario || !version_id) {
      return new Response(JSON.stringify({
        error: "uid_usuario y version_id son obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    const now = new Date().toISOString();
    /* =====================================================
       OBTENER VERSIÓN DESDE LA VISTA
       👉 CLAVE: id_estacion DEFINE EL TIPO DE ROLLBACK
    ===================================================== */ const { data: version, error: versionError } = await supabase.from("vw_historial_precios_por_zona").select("id_cliente, id_zona, id_estacion, id_combustible, precio").eq("version_id", version_id).maybeSingle();
    if (versionError || !version) {
      return new Response(JSON.stringify({
        error: "Versión no encontrada."
      }), {
        status: 404,
        headers
      });
    }
    const { id_cliente, id_zona, id_estacion, id_combustible, precio } = version;
    /* =====================================================
       RESOLVER ESTACIONES AFECTADAS
    ===================================================== */ let idsEstaciones = [];
    if (id_estacion) {
      // 🔹 ROLLBACK SOLO PARA UNA ESTACIÓN
      idsEstaciones = [
        id_estacion
      ];
    } else {
      // 🔹 ROLLBACK PARA TODA LA ZONA
      const { data: estaciones } = await supabase.from("ms_estaciones").select("id_estacion").eq("id_zona", id_zona).eq("estado", true);
      if (!estaciones || estaciones.length === 0) {
        return new Response(JSON.stringify({
          error: "No hay estaciones activas."
        }), {
          status: 404,
          headers
        });
      }
      idsEstaciones = estaciones.map((e)=>e.id_estacion);
    }
    /* =====================================================
       DATA BEFORE REAL (PRECIO VIGENTE ACTUAL)
    ===================================================== */ const { data: precioVigente } = await supabase.from("cb_precios_combustible").select("precio, fecha_inicio").eq("id_cliente", id_cliente).eq("id_combustible", id_combustible).in("id_estacion", idsEstaciones).eq("estado", true).is("fecha_fin", null).limit(1).maybeSingle();
    /* =====================================================
       CERRAR PRECIOS VIGENTES
    ===================================================== */ await supabase.from("cb_precios_combustible").update({
      estado: false,
      fecha_fin: now
    }).eq("id_cliente", id_cliente).eq("id_combustible", id_combustible).in("id_estacion", idsEstaciones).is("fecha_fin", null);
    /* =====================================================
       INSERTAR PRECIO RESTAURADO
    ===================================================== */ const inserts = idsEstaciones.map((id_est)=>({
        id_cliente,
        id_estacion: id_est,
        id_combustible,
        precio,
        fecha_inicio: now,
        estado: true
      }));
    await supabase.from("cb_precios_combustible").insert(inserts);
    /* =====================================================
       AUDITORÍA
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "cb_precios_combustible",
      accion: "ROLLBACK_PRECIO_POR_VERSION",
      registro_id: String(version_id),
      data_before: precioVigente ? {
        precio_vigente: precioVigente.precio,
        fecha_inicio: precioVigente.fecha_inicio,
        estaciones_afectadas: idsEstaciones.length
      } : null,
      data_after: {
        version_id,
        precio_restaurado: precio,
        tipo_rollback: id_estacion ? "ESTACION" : "ZONA",
        id_zona,
        id_estacion,
        fecha_aplicacion: now,
        estaciones_afectadas: idsEstaciones.length
      }
    });
    /* =====================================================
       RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: id_estacion ? "Rollback aplicado correctamente para la estación." : "Rollback aplicado correctamente para la zona.",
      precio_restaurado: precio,
      estaciones_afectadas: idsEstaciones.length,
      fecha_aplicacion: now
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "Error inesperado.",
      detalle: error.message
    }), {
      status: 500,
      headers
    });
  }
});
