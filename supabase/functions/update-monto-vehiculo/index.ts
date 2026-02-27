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
        error: "Solo se permite POST."
      }), {
        status: 405,
        headers
      });
    }
    const { uid_usuario, id_cliente, id_vehiculo, monto } = await req.json();
    if (!uid_usuario || id_cliente == null || id_vehiculo == null || monto == null || Number(monto) <= 0) {
      return new Response(JSON.stringify({
        error: "Datos inválidos."
      }), {
        status: 400,
        headers
      });
    }
    const nuevoMonto = Number(monto);
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       VEHÍCULO
    ===================================================== */ const { data: vehiculo } = await supabase.from("ms_vehiculos").select("*").eq("id_cliente", id_cliente).eq("id_vehiculo", id_vehiculo).maybeSingle();
    if (!vehiculo) {
      return new Response(JSON.stringify({
        error: "Vehículo no encontrado."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       CONSUMO ACTUAL (Estados 1 y 2)
    ===================================================== */ const { data: consumoRows } = await supabase.from("cb_abastecimientos").select("total").eq("id_vehiculo", id_vehiculo).in("id_estado", [
      1,
      2
    ]);
    const consumoActual = consumoRows?.reduce((s, r)=>s + Number(r.total ?? 0), 0) ?? 0;
    /* =====================================================
       🔒 VALIDACIÓN 1: No bajar de consumo
    ===================================================== */ if (nuevoMonto < consumoActual) {
      return new Response(JSON.stringify({
        error: "No se puede asignar menos del consumo actual.",
        placa: vehiculo.placa,
        consumido: consumoActual,
        monto_intentado: nuevoMonto
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       🔒 VALIDACIÓN 2: Saldo disponible real
       (usando tu función 2.0)
    ===================================================== */ const { data: saldoDisponible } = await supabase.rpc("fn_saldo_disponible_vehiculo", {
      p_id_vehiculo: id_vehiculo
    });
    const saldoReal = Number(saldoDisponible ?? 0);
    // Diferencia que queremos aumentar realmente
    const incremento = nuevoMonto - Number(vehiculo.monto_asignado ?? 0);
    if (incremento > saldoReal) {
      return new Response(JSON.stringify({
        error: "Excede el saldo disponible real del vehículo.",
        placa: vehiculo.placa,
        saldo_disponible: saldoReal,
        incremento_intentado: incremento
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       UPDATE
    ===================================================== */ await supabase.from("ms_vehiculos").update({
      monto_asignado: nuevoMonto
    }).eq("id_vehiculo", id_vehiculo);
    /* =====================================================
       AUDITORÍA
    ===================================================== */ const dataAfter = {
      ...vehiculo,
      monto_asignado: nuevoMonto
    };
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_vehiculos",
      accion: "UPDATE_MONTO_VEHICULO",
      registro_id: String(id_vehiculo),
      data_before: vehiculo,
      data_after: dataAfter
    });
    return new Response(JSON.stringify({
      success: true,
      message: `Monto actualizado para ${vehiculo.placa}`,
      consumo_actual: consumoActual,
      saldo_restante: saldoReal - incremento
    }), {
      status: 200,
      headers
    });
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({
      error: "Error inesperado."
    }), {
      status: 500,
      headers
    });
  }
});
