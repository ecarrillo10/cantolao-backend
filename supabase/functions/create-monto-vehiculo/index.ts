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
    const { uid_usuario, id_cliente, vehiculos, monto } = await req.json();
    if (!uid_usuario || id_cliente == null || !Array.isArray(vehiculos) || vehiculos.length === 0 || monto == null || Number(monto) <= 0) {
      return new Response(JSON.stringify({
        error: "Datos inválidos."
      }), {
        status: 400,
        headers
      });
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       VEHÍCULOS A MODIFICAR
    ===================================================== */ const { data: vehiculosDB } = await supabase.from("ms_vehiculos").select("*").eq("id_cliente", id_cliente).in("id_vehiculo", vehiculos);
    if (!vehiculosDB || vehiculosDB.length !== vehiculos.length) {
      return new Response(JSON.stringify({
        error: "Uno o más vehículos no son válidos."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       CONSUMO ACTUAL (Estados 1 y 2)
    ===================================================== */ const { data: consumos } = await supabase.from("cb_abastecimientos").select("id_vehiculo, total").in("id_vehiculo", vehiculos).in("id_estado", [
      1,
      2
    ]);
    const consumoMap = new Map();
    for (const c of consumos ?? []){
      consumoMap.set(c.id_vehiculo, (consumoMap.get(c.id_vehiculo) ?? 0) + Number(c.total ?? 0));
    }
    const errores = [];
    /* =====================================================
       VALIDACIONES
    ===================================================== */ for (const veh of vehiculosDB){
      const consumoActual = consumoMap.get(veh.id_vehiculo) ?? 0;
      // 🔥 1️⃣ No permitir monto menor al consumo actual
      if (Number(monto) < consumoActual) {
        errores.push(`Vehículo ${veh.placa} no puede tener un monto menor a su consumo actual (${consumoActual}).`);
        continue;
      }
      // 🔥 2️⃣ Obtener saldo disponible REAL
      const { data: saldoDisponible } = await supabase.rpc("fn_saldo_disponible_vehiculo", {
        p_id_vehiculo: veh.id_vehiculo
      });
      const saldoActual = Number(saldoDisponible ?? 0);
      // 🔥 3️⃣ Validar que no exceda saldo real disponible
      const nuevoDisponible = Number(monto) - consumoActual;
      if (nuevoDisponible > saldoActual) {
        errores.push(`Vehículo ${veh.placa} excede el saldo disponible real (${saldoActual}).`);
      }
    }
    if (errores.length > 0) {
      return new Response(JSON.stringify({
        error: errores.join(" | ")
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       UPDATE FINAL
    ===================================================== */ for (const id_vehiculo of vehiculos){
      await supabase.from("ms_vehiculos").update({
        monto_asignado: monto
      }).eq("id_vehiculo", id_vehiculo);
    }
    /* =====================================================
       AUDITORÍA
    ===================================================== */ const dataAfter = vehiculosDB.map((v)=>({
        ...v,
        monto_asignado: monto
      }));
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_vehiculos",
      accion: "UPDATE_MONTO_VEHICULOS",
      registro_id: vehiculos.join(","),
      data_before: vehiculosDB,
      data_after: dataAfter
    });
    return new Response(JSON.stringify({
      message: "Monto asignado correctamente a los vehículos."
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
