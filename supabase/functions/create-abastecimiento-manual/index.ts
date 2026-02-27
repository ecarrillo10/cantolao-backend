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
    ===================================================== */ const { id_estacion, id_cliente, id_vehiculo, id_conductor, id_combustible, galones, precio_unitario, kilometraje, fecha_hora, id_operador, usuario_admin_uuid } = await req.json();
    if (!id_estacion || !id_cliente || !id_vehiculo || !id_conductor || !id_combustible || galones == null || precio_unitario == null) {
      return new Response(JSON.stringify({
        error: "Completa todos los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    const gal = Number(galones);
    const precio = Number(precio_unitario);
    const total = gal * precio;
    if (gal <= 0 || precio <= 0) {
      return new Response(JSON.stringify({
        error: "Los galones y el precio deben ser mayores a cero."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       2️⃣ FECHA OPCIONAL
    ===================================================== */ let fechaFinal;
    if (fecha_hora) {
      const f = new Date(fecha_hora);
      if (isNaN(f.getTime())) {
        return new Response(JSON.stringify({
          error: "La fecha ingresada no es válida."
        }), {
          status: 400,
          headers
        });
      }
      fechaFinal = f.toISOString();
    } else {
      fechaFinal = new Date().toISOString();
    }
    /* =====================================================
       3️⃣ SUPABASE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       4️⃣ VALIDAR LINEA CREDITO
    ===================================================== */ const { data: linea, error: lineaError } = await supabase.from("cb_lineas").select("id_linea, monto_asignado").eq("id_cliente", id_cliente).eq("estado", true).single();
    if (lineaError || !linea) {
      return new Response(JSON.stringify({
        error: "El cliente no tiene una línea de crédito activa."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       5️⃣ SUM CONSUMO — ESTABLE (SIN sum())
    ===================================================== */ const { data: consumos, error: sumError } = await supabase.from("cb_abastecimientos").select("total").eq("id_cliente", id_cliente).in("id_estado", [
      1,
      2
    ]);
    if (sumError) {
      return new Response(JSON.stringify({
        error: "No se pudo validar el saldo disponible."
      }), {
        status: 500,
        headers
      });
    }
    const usado = consumos?.reduce((acc, r)=>acc + Number(r.total), 0) || 0;
    const saldoDisponible = Number(linea.monto_asignado) - usado;
    if (total > saldoDisponible) {
      return new Response(JSON.stringify({
        error: `Saldo insuficiente. Disponible: ${saldoDisponible.toFixed(2)}`
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       6️⃣ CREAR QR INTERNO OBLIGATORIO
    ===================================================== */ const { data: qr, error: qrError } = await supabase.from("cb_qr_generados").insert({
      id_conductor,
      id_vehiculo,
      id_combustible,
      id_estacion,
      id_estado: 6
    }).select().single();
    if (qrError || !qr) {
      return new Response(JSON.stringify({
        error: "No se pudo generar el QR interno."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       7️⃣ INSERT ABASTECIMIENTO
    ===================================================== */ const { data: ab, error: abError } = await supabase.from("cb_abastecimientos").insert({
      id_estacion,
      id_cliente,
      id_vehiculo,
      id_conductor,
      id_combustible,
      galones: gal,
      total,
      kilometraje,
      fecha_hora: fechaFinal,
      id_operador: id_operador ?? null,
      id_estado: 1,
      qrgenerado: qr.id_qr
    }).select().single();
    if (abError || !ab) {
      return new Response(JSON.stringify({
        error: "No se pudo registrar el abastecimiento."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       8️⃣ AUDITORIA
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: usuario_admin_uuid,
      tabla_afectada: "cb_abastecimientos",
      accion: "CONCILIACION_MANUAL",
      registro_id: ab.id_abastecimiento.toString(),
      data_after: ab
    });
    /* =====================================================
       9️⃣ RESPUESTA OK
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Abastecimiento conciliado correctamente.",
      id_abastecimiento: ab.id_abastecimiento,
      qr: qr.id_qr,
      total,
      saldo_restante: saldoDisponible - total,
      fecha_registrada: fechaFinal
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "Ocurrió un error inesperado. Inténtalo nuevamente."
    }), {
      status: 500,
      headers
    });
  }
});
