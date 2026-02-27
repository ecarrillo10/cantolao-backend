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
    // =====================================================
    // SOLO POST
    // =====================================================
    if (req.method !== "POST") {
      return new Response(JSON.stringify({
        error: "Solo se permite el método POST."
      }), {
        status: 405,
        headers
      });
    }
    // =====================================================
    // BODY
    // =====================================================
    const { uid_usuario, id_cliente, id_tipo_linea, id_periodo_facturacion, monto_asignado, plazo_de_pago } = await req.json();
    // ===============================
    // VALIDACIONES GENERALES
    // ===============================
    if (!uid_usuario || id_cliente == null || id_tipo_linea == null) {
      return new Response(JSON.stringify({
        error: "uid_usuario, id_cliente e id_tipo_linea son obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    if (monto_asignado == null || Number(monto_asignado) <= 0) {
      return new Response(JSON.stringify({
        error: "El monto_asignado es obligatorio y debe ser mayor a cero."
      }), {
        status: 400,
        headers
      });
    }
    // =====================================================
    // SERVICE ROLE
    // =====================================================
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // =====================================================
    // VALIDAR CLIENTE
    // =====================================================
    const { data: cliente } = await supabase.from("ms_clientes").select("id_cliente").eq("id_cliente", id_cliente).maybeSingle();
    if (!cliente) {
      return new Response(JSON.stringify({
        error: "El cliente no existe."
      }), {
        status: 404,
        headers
      });
    }
    // =====================================================
    // VALIDAR TIPO DE LÍNEA
    // =====================================================
    const { data: tipoLinea } = await supabase.from("ms_tipos_linea_credito").select("id_tipo_linea").eq("id_tipo_linea", id_tipo_linea).maybeSingle();
    if (!tipoLinea) {
      return new Response(JSON.stringify({
        error: "El tipo de línea de crédito no existe."
      }), {
        status: 404,
        headers
      });
    }
    // =====================================================
    // 🔐 VALIDAR LÍNEA ACTIVA EXISTENTE
    // =====================================================
    const { data: lineaActiva } = await supabase.from("cb_lineas").select("id_linea").eq("id_cliente", id_cliente).eq("estado", true).maybeSingle();
    if (lineaActiva) {
      return new Response(JSON.stringify({
        error: "El cliente ya tiene una línea de crédito activa."
      }), {
        status: 409,
        headers
      });
    }
    // =====================================================
    // REGLA POR TIPO DE LÍNEA
    // =====================================================
    let periodoFinal = null;
    let plazoFinal = null;
    if (id_tipo_linea === 1) {
      // CRÉDITO
      if (id_periodo_facturacion == null || plazo_de_pago == null || Number(plazo_de_pago) <= 0) {
        return new Response(JSON.stringify({
          error: "Para líneas de CRÉDITO son obligatorios id_periodo_facturacion y plazo_de_pago."
        }), {
          status: 400,
          headers
        });
      }
      const { data: periodo } = await supabase.from("ms_periodos_facturacion").select("id_periodo").eq("id_periodo", id_periodo_facturacion).maybeSingle();
      if (!periodo) {
        return new Response(JSON.stringify({
          error: "El periodo de facturación no existe."
        }), {
          status: 404,
          headers
        });
      }
      periodoFinal = id_periodo_facturacion;
      plazoFinal = Number(plazo_de_pago);
    }
    // =====================================================
    // INSERTAR LÍNEA
    // =====================================================
    const { data, error } = await supabase.from("cb_lineas").insert({
      id_cliente,
      id_tipo_linea,
      id_periodo_facturacion: periodoFinal,
      monto_asignado,
      plazo_de_pago: plazoFinal,
      estado: true
    }).select("*").single();
    if (error) {
      return new Response(JSON.stringify({
        error: "No se pudo crear la línea de crédito.",
        detalle: error.message
      }), {
        status: 500,
        headers
      });
    }
    // =====================================================
    // 📘 AUDITORÍA
    // =====================================================
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "cb_lineas",
      accion: "CREATE_LINEA_CREDITO",
      registro_id: String(data.id_linea),
      data_before: null,
      data_after: data
    });
    // =====================================================
    // RESPUESTA FINAL
    // =====================================================
    return new Response(JSON.stringify({
      success: true,
      message: "Línea de crédito creada correctamente.",
      id_linea: data.id_linea
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "Ocurrió un error inesperado.",
      detalle: error.message
    }), {
      status: 500,
      headers
    });
  }
});
