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
    const { id_cliente, id_vehiculo } = await req.json();
    if (!id_cliente || !id_vehiculo) {
      return new Response(JSON.stringify({
        error: "Datos inválidos."
      }), {
        status: 400,
        headers
      });
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       1️⃣ VALIDAR LÍNEA ACTIVA
    ===================================================== */ const { data: linea } = await supabase.from("cb_lineas").select("monto_asignado").eq("id_cliente", id_cliente).eq("estado", true).maybeSingle();
    if (!linea) {
      return new Response(JSON.stringify({
        error: "Cliente sin línea activa."
      }), {
        status: 409,
        headers
      });
    }
    const montoLinea = Number(linea.monto_asignado ?? 0);
    /* =====================================================
       2️⃣ VALIDAR VEHÍCULO
    ===================================================== */ const { data: vehiculo } = await supabase.from("ms_vehiculos").select("id_vehiculo, placa, id_centro_costo").eq("id_vehiculo", id_vehiculo).eq("id_cliente", id_cliente).maybeSingle();
    if (!vehiculo) {
      return new Response(JSON.stringify({
        error: "El vehículo no existe."
      }), {
        status: 404,
        headers
      });
    }
    if (!vehiculo.id_centro_costo) {
      return new Response(JSON.stringify({
        error: `El vehículo ${vehiculo.placa} no tiene centro asignado.`
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       3️⃣ CALCULAR TOTAL CENTROS
    ===================================================== */ const { data: centros } = await supabase.from("ms_centro_costo").select("monto_asignado").eq("id_cliente", id_cliente).eq("estado", true);
    const totalCentros = centros?.reduce((s, c)=>s + Number(c.monto_asignado ?? 0), 0) ?? 0;
    /* =====================================================
       4️⃣ VEHÍCULOS SIN CENTRO CON MONTO
    ===================================================== */ const { data: vehiculosSinCentro } = await supabase.from("ms_vehiculos").select("monto_asignado").eq("id_cliente", id_cliente).is("id_centro_costo", null);
    const totalVehiculosSinCentro = vehiculosSinCentro?.reduce((s, v)=>s + Number(v.monto_asignado ?? 0), 0) ?? 0;
    /* =====================================================
       5️⃣ CONSUMO VEHÍCULOS SIN MONTO ASIGNADO
    ===================================================== */ const { data: consumoRows } = await supabase.from("cb_abastecimientos").select("total, id_vehiculo").eq("id_cliente", id_cliente).in("id_estado", [
      1,
      2
    ]);
    let consumoSinMonto = 0;
    for (const r of consumoRows ?? []){
      const { data: veh } = await supabase.from("ms_vehiculos").select("monto_asignado").eq("id_vehiculo", r.id_vehiculo).maybeSingle();
      if (!veh?.monto_asignado) {
        consumoSinMonto += Number(r.total ?? 0);
      }
    }
    /* =====================================================
       6️⃣ VALIDACIÓN GLOBAL
    ===================================================== */ if (totalCentros + totalVehiculosSinCentro + consumoSinMonto > montoLinea) {
      return new Response(JSON.stringify({
        error: "No se puede retirar el vehículo porque excedería el saldo global permitido por la línea."
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       7️⃣ UPDATE FINAL
    ===================================================== */ await supabase.from("ms_vehiculos").update({
      id_centro_costo: null
    }).eq("id_vehiculo", id_vehiculo);
    return new Response(JSON.stringify({
      success: true,
      message: `El vehículo ${vehiculo.placa} fue retirado correctamente del centro de costo.`
    }), {
      status: 200,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "Error inesperado."
    }), {
      status: 500,
      headers
    });
  }
});
