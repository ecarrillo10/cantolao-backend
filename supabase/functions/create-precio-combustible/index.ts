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
    ===================================================== */ const { uid_usuario, id_cliente, id_zona, id_estacion, id_combustible, precio } = await req.json();
    if (!uid_usuario || id_cliente == null || id_zona == null || id_combustible == null || precio == null) {
      return new Response(JSON.stringify({
        error: "Completa todos los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    // 👉 Validación especial zona 12
    if (id_zona === 12 && !id_estacion) {
      return new Response(JSON.stringify({
        error: "Para la zona 12 es obligatorio seleccionar una estación."
      }), {
        status: 400,
        headers
      });
    }
    if (Number(precio) <= 0) {
      return new Response(JSON.stringify({
        error: "El precio debe ser mayor a cero."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       2️⃣ SUPABASE SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       3️⃣ OBTENER ESTACIONES
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
      if (error) {
        return new Response(JSON.stringify({
          error: "Error al obtener estaciones de la zona."
        }), {
          status: 500,
          headers
        });
      }
      if (!data || data.length === 0) {
        return new Response(JSON.stringify({
          error: "La zona no tiene estaciones activas asociadas."
        }), {
          status: 404,
          headers
        });
      }
      estaciones = data;
    }
    /* =====================================================
       4️⃣ FECHA DEL PROCESO
    ===================================================== */ const inicioProceso = new Date().toISOString();
    const preciosCreados = [];
    /* =====================================================
       5️⃣ PROCESAR ESTACIONES
    ===================================================== */ for (const estacion of estaciones){
      const id_est = estacion.id_estacion;
      const { data: precioActivo } = await supabase.from("cb_precios_combustible").select("id_precio").eq("id_cliente", id_cliente).eq("id_estacion", id_est).eq("id_combustible", id_combustible).eq("estado", true).is("fecha_fin", null).lte("fecha_inicio", inicioProceso).maybeSingle();
      if (precioActivo) {
        const { error } = await supabase.from("cb_precios_combustible").update({
          estado: false,
          fecha_fin: inicioProceso
        }).eq("id_precio", precioActivo.id_precio);
        if (error) {
          return new Response(JSON.stringify({
            error: "No se pudo cerrar el precio anterior."
          }), {
            status: 500,
            headers
          });
        }
      }
      const { data: nuevoPrecio, error } = await supabase.from("cb_precios_combustible").insert({
        id_cliente,
        id_estacion: id_est,
        id_combustible,
        precio,
        fecha_inicio: inicioProceso,
        estado: true
      }).select("id_precio").single();
      if (error || !nuevoPrecio) {
        return new Response(JSON.stringify({
          error: "No se pudo registrar el precio."
        }), {
          status: 500,
          headers
        });
      }
      preciosCreados.push(nuevoPrecio.id_precio);
    }
    /* =====================================================
       6️⃣ AUDITORÍA
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "cb_precios_combustible",
      accion: "INSERT_PRECIO_ZONA",
      registro_id: JSON.stringify(preciosCreados),
      data_before: null,
      data_after: {
        id_cliente,
        id_zona,
        id_estacion: id_zona === 12 ? id_estacion : null,
        id_combustible,
        precio,
        fecha_aplicacion: inicioProceso,
        estaciones_afectadas: estaciones.length,
        id_precios: preciosCreados
      }
    });
    /* =====================================================
       7️⃣ RESPUESTA
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: id_zona === 12 ? "Precio registrado correctamente para la estación seleccionada." : "Precios registrados correctamente por zona.",
      estaciones_afectadas: estaciones.length,
      fecha_aplicacion: inicioProceso
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
