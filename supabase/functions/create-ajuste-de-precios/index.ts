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
        error: "Método no permitido"
      }), {
        status: 405,
        headers
      });
    }
    /* =====================================================
       BODY
    ===================================================== */ const { uid_usuario, id_zona, id_estacion, id_combustible, ajuste } = await req.json();
    if (!uid_usuario || id_zona == null || id_combustible == null || ajuste == null) {
      return new Response(JSON.stringify({
        error: "Completa todos los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    // 👉 Regla especial zona 12
    if (id_zona === 12 && !id_estacion) {
      return new Response(JSON.stringify({
        error: "Para la zona 12 es obligatorio seleccionar una estación."
      }), {
        status: 400,
        headers
      });
    }
    if (typeof ajuste !== "number") {
      return new Response(JSON.stringify({
        error: "El ajuste debe ser un número."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    const inicioProceso = new Date().toISOString();
    /* =====================================================
       ESTACIONES AFECTADAS
    ===================================================== */ let estaciones = [];
    if (id_zona === 12) {
      // 🔹 SOLO UNA ESTACIÓN
      const { data, error } = await supabase.from("ms_estaciones").select("id_estacion").eq("id_estacion", id_estacion).eq("id_zona", id_zona).eq("estado", true).maybeSingle();
      if (error || !data) {
        return new Response(JSON.stringify({
          error: "La estación no existe, no pertenece a la zona o está inactiva."
        }), {
          status: 404,
          headers
        });
      }
      estaciones = [
        data
      ];
    } else {
      // 🔹 TODAS LAS ESTACIONES DE LA ZONA
      const { data, error } = await supabase.from("ms_estaciones").select("id_estacion").eq("id_zona", id_zona).eq("estado", true);
      if (error || !data || data.length === 0) {
        return new Response(JSON.stringify({
          error: "No existen estaciones activas en la zona seleccionada."
        }), {
          status: 404,
          headers
        });
      }
      estaciones = data;
    }
    const idsEstaciones = estaciones.map((e)=>e.id_estacion);
    /* =====================================================
       PRECIOS VIGENTES (DATA BEFORE)
    ===================================================== */ const { data: precios } = await supabase.from("cb_precios_combustible").select("*").in("id_estacion", idsEstaciones).eq("id_combustible", id_combustible).eq("estado", true).is("fecha_fin", null).lte("fecha_inicio", inicioProceso);
    if (!precios || precios.length === 0) {
      return new Response(JSON.stringify({
        error: "No existen precios vigentes para aplicar el ajuste."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       APLICAR AJUSTE
    ===================================================== */ const preciosAntes = [];
    const preciosDespues = [];
    for (const precio of precios){
      const nuevoPrecio = Number(precio.precio) + ajuste;
      if (nuevoPrecio <= 0) {
        return new Response(JSON.stringify({
          error: "El ajuste genera precios inválidos (≤ 0). Operación cancelada."
        }), {
          status: 400,
          headers
        });
      }
      preciosAntes.push({
        id_precio: precio.id_precio,
        id_estacion: precio.id_estacion,
        precio: precio.precio,
        fecha_inicio: precio.fecha_inicio
      });
      // cerrar precio actual
      await supabase.from("cb_precios_combustible").update({
        estado: false,
        fecha_fin: inicioProceso
      }).eq("id_precio", precio.id_precio);
      // insertar nuevo precio
      await supabase.from("cb_precios_combustible").insert({
        id_cliente: precio.id_cliente,
        id_estacion: precio.id_estacion,
        id_combustible: precio.id_combustible,
        precio: nuevoPrecio,
        fecha_inicio: inicioProceso,
        estado: true
      });
      preciosDespues.push({
        id_estacion: precio.id_estacion,
        precio_anterior: precio.precio,
        precio_nuevo: nuevoPrecio
      });
    }
    /* =====================================================
       AUDITORÍA
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "cb_precios_combustible",
      accion: "AJUSTE_PRECIO_POR_ZONA",
      registro_id: `Z${id_zona}-C${id_combustible}-${inicioProceso}`,
      data_before: {
        id_zona,
        id_estacion: id_zona === 12 ? id_estacion : null,
        id_combustible,
        precios: preciosAntes
      },
      data_after: {
        ajuste_aplicado: ajuste,
        precios: preciosDespues,
        fecha_aplicacion: inicioProceso
      }
    });
    /* =====================================================
       RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: id_zona === 12 ? "Ajuste aplicado correctamente a la estación seleccionada." : "Ajuste de precios aplicado correctamente por zona.",
      estaciones_afectadas: idsEstaciones.length,
      precios_actualizados: precios.length,
      ajuste_aplicado: ajuste
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({
      error: "Ocurrió un error inesperado. Inténtalo más tarde."
    }), {
      status: 500,
      headers
    });
  }
});
