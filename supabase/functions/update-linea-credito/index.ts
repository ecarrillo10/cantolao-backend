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
    const { uid_usuario, id_linea, id_tipo_linea, id_periodo_facturacion, monto_asignado, plazo_de_pago, estado } = await req.json();
    if (!uid_usuario || !id_linea) {
      return new Response(JSON.stringify({
        error: "uid_usuario e id_linea son obligatorios."
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
    // OBTENER LÍNEA ACTUAL
    // =====================================================
    const { data: lineaActual } = await supabase.from("cb_lineas").select("*").eq("id_linea", id_linea).maybeSingle();
    if (!lineaActual) {
      return new Response(JSON.stringify({
        error: "La línea de crédito no existe."
      }), {
        status: 404,
        headers
      });
    }
    const id_cliente = lineaActual.id_cliente;
    const tipoFinal = id_tipo_linea ?? lineaActual.id_tipo_linea;
    // =====================================================
    // 🔒 VALIDAR NO REDUCIR MENOS DE LO CONSUMIDO
    // =====================================================
    const { data: consumoRows, error: consumoError } = await supabase.from("cb_abastecimientos").select("total").eq("id_cliente", id_cliente).in("id_estado", [
      1,
      2
    ]);
    if (consumoError) {
      return new Response(JSON.stringify({
        error: "No se pudo calcular el consumo actual.",
        detalle: consumoError.message
      }), {
        status: 500,
        headers
      });
    }
    const totalConsumido = consumoRows?.reduce((sum, r)=>sum + Number(r.total || 0), 0) ?? 0;
    if (Number(monto_asignado) < totalConsumido) {
      return new Response(JSON.stringify({
        error: "No se puede reducir la línea por debajo de lo consumido.",
        consumido_actual: totalConsumido,
        monto_intentado: monto_asignado
      }), {
        status: 409,
        headers
      });
    }
    // =====================================================
    // VALIDAR TIPO DE LÍNEA
    // =====================================================
    const { data: tipo } = await supabase.from("ms_tipos_linea_credito").select("id_tipo_linea").eq("id_tipo_linea", tipoFinal).maybeSingle();
    if (!tipo) {
      return new Response(JSON.stringify({
        error: "El tipo de línea de crédito no existe."
      }), {
        status: 404,
        headers
      });
    }
    // =====================================================
    // REGLA DE NEGOCIO POR TIPO
    // =====================================================
    let periodoFinal = null;
    let plazoFinal = null;
    if (tipoFinal === 1) {
      if (id_periodo_facturacion == null || plazo_de_pago == null || Number(plazo_de_pago) <= 0) {
        return new Response(JSON.stringify({
          error: "Para líneas de CRÉDITO son obligatorios: id_periodo_facturacion y plazo_de_pago."
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
    // 🔐 VALIDAR UNA SOLA ACTIVA
    // =====================================================
    if (estado === true && lineaActual.estado === false) {
      const { data: otraActiva } = await supabase.from("cb_lineas").select("id_linea").eq("id_cliente", id_cliente).eq("estado", true).neq("id_linea", id_linea).maybeSingle();
      if (otraActiva) {
        return new Response(JSON.stringify({
          error: "El cliente ya tiene otra línea de crédito activa."
        }), {
          status: 409,
          headers
        });
      }
    }
    // =====================================================
    // UPDATE
    // =====================================================
    const dataAfter = {
      ...lineaActual,
      id_tipo_linea: tipoFinal,
      id_periodo_facturacion: periodoFinal,
      monto_asignado,
      plazo_de_pago: plazoFinal,
      estado: estado ?? lineaActual.estado
    };
    const { error: updateError } = await supabase.from("cb_lineas").update({
      id_tipo_linea: tipoFinal,
      id_periodo_facturacion: periodoFinal,
      monto_asignado,
      plazo_de_pago: plazoFinal,
      estado: estado ?? lineaActual.estado
    }).eq("id_linea", id_linea);
    if (updateError) {
      return new Response(JSON.stringify({
        error: "No se pudo actualizar la línea de crédito.",
        detalle: updateError.message
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
      accion: "UPDATE_LINEA_CREDITO",
      registro_id: String(id_linea),
      data_before: lineaActual,
      data_after: dataAfter
    });
    // =====================================================
    // RESPUESTA
    // =====================================================
    return new Response(JSON.stringify({
      success: true,
      message: "Línea de crédito actualizada correctamente.",
      consumido_actual: totalConsumido
    }), {
      status: 200,
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
