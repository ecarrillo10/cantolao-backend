import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  // =====================================================
  // CORS
  // =====================================================
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
        success: false,
        message: "Solo se permite el método POST."
      }), {
        status: 405,
        headers
      });
    }
    // =====================================================
    // SUPABASE SERVICE ROLE
    // =====================================================
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // =====================================================
    // BODY
    // =====================================================
    const { uid_usuario, id_cliente, id_zona, id_estacion, id_combustible, precio } = await req.json();
    if (!uid_usuario || id_cliente == null || id_zona == null || id_combustible == null || precio == null) {
      return new Response(JSON.stringify({
        success: false,
        message: "Completa todos los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    const precioNum = Number(precio);
    if (isNaN(precioNum) || precioNum <= 0) {
      return new Response(JSON.stringify({
        success: false,
        message: "El precio debe ser numérico y mayor a cero."
      }), {
        status: 400,
        headers
      });
    }
    // =====================================================
    // VALIDAR ZONA
    // (recomendado: aquí podrías tener flag requiere_estacion_individual)
    // =====================================================
    const { data: zona, error: zonaError } = await supabase.from("ms_zonas").select("id_zona").eq("id_zona", id_zona).maybeSingle();
    if (zonaError || !zona) {
      return new Response(JSON.stringify({
        success: false,
        message: "Zona no existe."
      }), {
        status: 404,
        headers
      });
    }
    // =====================================================
    // ⚠️ REGLA ESPECIAL ZONA 12 (MISMA QUE CREAR PRECIO)
    // =====================================================
    if (id_zona === 12 && !id_estacion) {
      return new Response(JSON.stringify({
        success: false,
        message: "Para la zona 12 debes seleccionar una estación."
      }), {
        status: 400,
        headers
      });
    }
    // =====================================================
    // OBTENER ESTACIONES SEGÚN LÓGICA DE NEGOCIO
    // =====================================================
    let estaciones = [];
    if (id_zona === 12) {
      // 🔹 SOLO UNA ESTACIÓN
      const { data, error } = await supabase.from("ms_estaciones").select("id_estacion").eq("id_estacion", id_estacion).eq("id_zona", id_zona).eq("estado", true).maybeSingle();
      if (error || !data) {
        return new Response(JSON.stringify({
          success: false,
          message: "La estación no es válida para la zona o está inactiva."
        }), {
          status: 404,
          headers
        });
      }
      estaciones = [
        data
      ];
    } else {
      // 🔹 TODAS LAS ESTACIONES ACTIVAS DE LA ZONA
      const { data, error } = await supabase.from("ms_estaciones").select("id_estacion").eq("id_zona", id_zona).eq("estado", true);
      if (error || !data || data.length === 0) {
        return new Response(JSON.stringify({
          success: false,
          message: "No hay estaciones activas en la zona."
        }), {
          status: 404,
          headers
        });
      }
      estaciones = data;
    }
    const idsEstaciones = estaciones.map((e)=>e.id_estacion);
    // =====================================================
    // OBTENER PRECIOS VIGENTES (ANTES) — PARA AUDITORÍA
    // =====================================================
    const { data: preciosAntes, error: preError } = await supabase.from("cb_precios_combustible").select("*").eq("id_cliente", id_cliente).eq("id_combustible", id_combustible).in("id_estacion", idsEstaciones).eq("estado", true).is("fecha_fin", null);
    if (preError || !preciosAntes || preciosAntes.length === 0) {
      return new Response(JSON.stringify({
        success: false,
        message: "No existen precios vigentes para editar."
      }), {
        status: 404,
        headers
      });
    }
    const idsPrecios = preciosAntes.map((p)=>p.id_precio);
    // =====================================================
    // UPDATE PRECIO VIGENTE
    // =====================================================
    const { error: updateError } = await supabase.from("cb_precios_combustible").update({
      precio: precioNum
    }).eq("id_cliente", id_cliente).eq("id_combustible", id_combustible).in("id_estacion", idsEstaciones).eq("estado", true).is("fecha_fin", null);
    if (updateError) {
      return new Response(JSON.stringify({
        success: false,
        message: "Error al actualizar precios.",
        error: updateError.message
      }), {
        status: 500,
        headers
      });
    }
    // =====================================================
    // AUDITORÍA
    // =====================================================
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "cb_precios_combustible",
      accion: "UPDATE_PRECIO_ZONA",
      registro_id: JSON.stringify(idsPrecios),
      data_before: preciosAntes,
      data_after: {
        precio_nuevo: precioNum,
        id_cliente,
        id_zona,
        id_estacion: id_zona === 12 ? id_estacion : null,
        id_combustible,
        estaciones_afectadas: idsEstaciones.length
      }
    });
    // =====================================================
    // RESPUESTA
    // =====================================================
    return new Response(JSON.stringify({
      success: true,
      message: id_zona === 12 ? "Precio actualizado para la estación." : "Precio actualizado para la zona.",
      estaciones_afectadas: idsEstaciones.length
    }), {
      status: 200,
      headers
    });
  } catch (error) {
    return new Response(JSON.stringify({
      success: false,
      message: "Error inesperado.",
      error: error.message
    }), {
      status: 500,
      headers
    });
  }
});
