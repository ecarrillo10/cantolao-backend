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
    const { uid_usuario, id_cliente, id_vehiculo, id_centro_costo_nuevo } = await req.json();
    if (!uid_usuario || !id_cliente || !id_vehiculo || !id_centro_costo_nuevo) {
      return new Response(JSON.stringify({
        error: "Datos inválidos."
      }), {
        status: 400,
        headers
      });
    }
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
       2️⃣ VEHÍCULO
    ===================================================== */ const { data: vehiculo } = await supabase.from("ms_vehiculos").select("*") // ← para auditoría completa
    .eq("id_vehiculo", id_vehiculo).eq("id_cliente", id_cliente).maybeSingle();
    if (!vehiculo) {
      return new Response(JSON.stringify({
        error: "Vehículo no encontrado."
      }), {
        status: 404,
        headers
      });
    }
    // 🔹 AUDITORÍA BEFORE
    const dataBefore = {
      ...vehiculo
    };
    /* =====================================================
       3️⃣ CONSUMO VEHÍCULO
    ===================================================== */ const { data: consumoRows } = await supabase.from("cb_abastecimientos").select("total").eq("id_vehiculo", id_vehiculo).in("id_estado", [
      1,
      2
    ]);
    const consumoVehiculo = consumoRows?.reduce((s, r)=>s + Number(r.total ?? 0), 0) ?? 0;
    const impactoFinanciero = vehiculo.monto_asignado != null ? Number(vehiculo.monto_asignado) : consumoVehiculo;
    /* =====================================================
       4️⃣ CENTRO NUEVO
    ===================================================== */ const { data: centroNuevo } = await supabase.from("ms_centro_costo").select("id_centro_costo, nombre, monto_asignado").eq("id_centro_costo", id_centro_costo_nuevo).eq("id_cliente", id_cliente).eq("estado", true).maybeSingle();
    if (!centroNuevo) {
      return new Response(JSON.stringify({
        error: "Centro inválido."
      }), {
        status: 404,
        headers
      });
    }
    const limiteCentroNuevo = Number(centroNuevo.monto_asignado ?? 0);
    /* =====================================================
       5️⃣ VALIDAR CONTRA CENTRO NUEVO
    ===================================================== */ const { data: vehiculosCentroNuevo } = await supabase.from("ms_vehiculos").select("monto_asignado").eq("id_centro_costo", id_centro_costo_nuevo).eq("id_cliente", id_cliente);
    const totalAsignadoNuevoCentro = vehiculosCentroNuevo?.reduce((s, v)=>s + Number(v.monto_asignado ?? 0), 0) ?? 0;
    if (totalAsignadoNuevoCentro + impactoFinanciero > limiteCentroNuevo) {
      return new Response(JSON.stringify({
        error: `El centro ${centroNuevo.nombre} no tiene saldo suficiente.`
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       6️⃣ VALIDACIÓN GLOBAL CONTRA LÍNEA
    ===================================================== */ const { data: centros } = await supabase.from("ms_centro_costo").select("monto_asignado").eq("id_cliente", id_cliente).eq("estado", true);
    let totalCentros = centros?.reduce((s, c)=>s + Number(c.monto_asignado ?? 0), 0) ?? 0;
    const { data: vehiculosSinCentro } = await supabase.from("ms_vehiculos").select("monto_asignado").eq("id_cliente", id_cliente).is("id_centro_costo", null);
    let totalVehiculosSinCentro = vehiculosSinCentro?.reduce((s, v)=>s + Number(v.monto_asignado ?? 0), 0) ?? 0;
    const { data: consumoGlobalRows } = await supabase.from("cb_abastecimientos").select("total, id_vehiculo").eq("id_cliente", id_cliente).in("id_estado", [
      1,
      2
    ]);
    let consumoSinMonto = 0;
    for (const r of consumoGlobalRows ?? []){
      const { data: veh } = await supabase.from("ms_vehiculos").select("monto_asignado").eq("id_vehiculo", r.id_vehiculo).maybeSingle();
      if (!veh?.monto_asignado) {
        consumoSinMonto += Number(r.total ?? 0);
      }
    }
    if (totalCentros + totalVehiculosSinCentro + consumoSinMonto > topeLinea) {
      return new Response(JSON.stringify({
        error: "La operación excede el saldo global permitido por la línea."
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       7️⃣ UPDATE
    ===================================================== */ await supabase.from("ms_vehiculos").update({
      id_centro_costo: id_centro_costo_nuevo
    }).eq("id_vehiculo", id_vehiculo);
    // 🔹 AUDITORÍA AFTER
    const { data: vehiculoAfter } = await supabase.from("ms_vehiculos").select("*").eq("id_vehiculo", id_vehiculo).maybeSingle();
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_vehiculos",
      accion: "REASIGNAR_VEHICULO_CENTRO",
      registro_id: String(id_vehiculo),
      data_before: dataBefore,
      data_after: vehiculoAfter ?? null
    });
    return new Response(JSON.stringify({
      success: true,
      message: `Vehículo ${vehiculo.placa} reasignado correctamente.`
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
