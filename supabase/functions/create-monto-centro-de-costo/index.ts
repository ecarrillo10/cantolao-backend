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
        error: "Solo POST permitido."
      }), {
        status: 405,
        headers
      });
    }
    const { uid_usuario, id_cliente, id_centro_costo, monto } = await req.json();
    if (!uid_usuario || id_cliente == null || id_centro_costo == null || monto == null || Number(monto) <= 0) {
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
       1️⃣ LÍNEA ACTIVA
    ===================================================== */ const { data: linea } = await supabase.from("cb_lineas").select("monto_asignado").eq("id_cliente", id_cliente).eq("estado", true).maybeSingle();
    if (!linea) {
      return new Response(JSON.stringify({
        error: "Cliente sin línea activa."
      }), {
        status: 409,
        headers
      });
    }
    const topeLinea = Number(linea.monto_asignado ?? 0);
    /* =====================================================
       2️⃣ CENTRO ACTUAL (DATA BEFORE)
    ===================================================== */ const { data: centro } = await supabase.from("ms_centro_costo").select("*").eq("id_centro_costo", id_centro_costo).eq("id_cliente", id_cliente).eq("estado", true).maybeSingle();
    if (!centro) {
      return new Response(JSON.stringify({
        error: "Centro inválido."
      }), {
        status: 404,
        headers
      });
    }
    const montoActualCentro = Number(centro.monto_asignado ?? 0);
    const incremento = nuevoMonto - montoActualCentro;
    /* =====================================================
       3️⃣ IMPACTO GLOBAL REAL
    ===================================================== */ const { data: centros } = await supabase.from("ms_centro_costo").select("id_centro_costo, monto_asignado").eq("id_cliente", id_cliente).eq("estado", true);
    const totalOtrosCentros = centros?.reduce((s, c)=>s + (c.id_centro_costo === id_centro_costo ? 0 : Number(c.monto_asignado ?? 0)), 0) ?? 0;
    const { data: vehiculosSinCentroConMonto } = await supabase.from("ms_vehiculos").select("monto_asignado").eq("id_cliente", id_cliente).is("id_centro_costo", null).not("monto_asignado", "is", null);
    const totalSinCentroConMonto = vehiculosSinCentroConMonto?.reduce((s, v)=>s + Number(v.monto_asignado ?? 0), 0) ?? 0;
    const { data: consumoSinMontoRows } = await supabase.from("cb_abastecimientos").select("total, ms_vehiculos!inner(monto_asignado, id_cliente)").eq("ms_vehiculos.id_cliente", id_cliente).is("ms_vehiculos.monto_asignado", null).in("id_estado", [
      1,
      2
    ]);
    const consumoSinMonto = consumoSinMontoRows?.reduce((s, r)=>s + Number(r.total ?? 0), 0) ?? 0;
    const impactoGlobal = totalOtrosCentros + totalSinCentroConMonto + consumoSinMonto + nuevoMonto;
    const saldoLineaReal = topeLinea - impactoGlobal;
    if (incremento > 0 && saldoLineaReal < 0) {
      return new Response(JSON.stringify({
        error: "Excede el saldo real disponible de la línea.",
        saldo_disponible: topeLinea - (totalOtrosCentros + totalSinCentroConMonto + consumoSinMonto + montoActualCentro)
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       4️⃣ VALIDAR COMPROMETIDO DEL CENTRO
    ===================================================== */ const { data: vehiculosCentro } = await supabase.from("ms_vehiculos").select("id_vehiculo, monto_asignado").eq("id_centro_costo", id_centro_costo);
    let totalAsignadoVehiculos = 0;
    const sinMonto = [];
    for (const v of vehiculosCentro ?? []){
      if (v.monto_asignado != null) {
        totalAsignadoVehiculos += Number(v.monto_asignado);
      } else {
        sinMonto.push(v.id_vehiculo);
      }
    }
    let consumoSinMontoCentro = 0;
    if (sinMonto.length > 0) {
      const { data: consumoRows } = await supabase.from("cb_abastecimientos").select("total").in("id_vehiculo", sinMonto).in("id_estado", [
        1,
        2
      ]);
      consumoSinMontoCentro = consumoRows?.reduce((s, r)=>s + Number(r.total ?? 0), 0) ?? 0;
    }
    const comprometidoCentro = totalAsignadoVehiculos + consumoSinMontoCentro;
    if (nuevoMonto < comprometidoCentro) {
      return new Response(JSON.stringify({
        error: "No se puede reducir el centro por debajo del monto comprometido.",
        comprometido: comprometidoCentro
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       UPDATE
    ===================================================== */ await supabase.from("ms_centro_costo").update({
      monto_asignado: nuevoMonto
    }).eq("id_centro_costo", id_centro_costo);
    /* =====================================================
       AUDITORÍA
    ===================================================== */ const dataAfter = {
      ...centro,
      monto_asignado: nuevoMonto
    };
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_centro_costo",
      accion: "UPDATE_MONTO_CENTRO_COSTO",
      registro_id: String(id_centro_costo),
      data_before: centro,
      data_after: dataAfter
    });
    return new Response(JSON.stringify({
      success: true,
      message: "Centro actualizado correctamente."
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
