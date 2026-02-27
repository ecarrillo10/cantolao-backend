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
    const { uid_usuario, id_cliente, id_centro_costo, vehiculos } = await req.json();
    if (!uid_usuario || id_cliente == null || id_centro_costo == null || !Array.isArray(vehiculos) || vehiculos.length === 0) {
      return new Response(JSON.stringify({
        error: "Datos inválidos."
      }), {
        status: 400,
        headers
      });
    }
    // Normalizar y evitar duplicados
    const vehiculosIds = Array.from(new Set(vehiculos.map((x)=>Number(x)).filter((n)=>Number.isFinite(n))));
    if (vehiculosIds.length === 0) {
      return new Response(JSON.stringify({
        error: "Lista de vehículos inválida."
      }), {
        status: 400,
        headers
      });
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       1) LÍNEA ACTIVA
    ===================================================== */ const { data: linea, error: lineaErr } = await supabase.from("cb_lineas").select("monto_asignado").eq("id_cliente", id_cliente).eq("estado", true).order("id_linea", {
      ascending: false
    }).limit(1).maybeSingle();
    if (lineaErr) {
      return new Response(JSON.stringify({
        error: lineaErr.message
      }), {
        status: 400,
        headers
      });
    }
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
       2) CENTRO ACTIVO
    ===================================================== */ const { data: centro, error: centroErr } = await supabase.from("ms_centro_costo").select("*").eq("id_centro_costo", id_centro_costo).eq("id_cliente", id_cliente).eq("estado", true).maybeSingle();
    if (centroErr) {
      return new Response(JSON.stringify({
        error: centroErr.message
      }), {
        status: 400,
        headers
      });
    }
    if (!centro) {
      return new Response(JSON.stringify({
        error: "Centro inválido o inactivo."
      }), {
        status: 404,
        headers
      });
    }
    const montoCentro = Number(centro.monto_asignado ?? 0);
    /* =====================================================
       3) VEHÍCULOS SELECCIONADOS (VALIDAR EXISTENCIA)
    ===================================================== */ const { data: vehiculosDB, error: vehErr } = await supabase.from("ms_vehiculos").select("id_vehiculo, placa, id_centro_costo, monto_asignado").eq("id_cliente", id_cliente).in("id_vehiculo", vehiculosIds);
    if (vehErr) {
      return new Response(JSON.stringify({
        error: vehErr.message
      }), {
        status: 400,
        headers
      });
    }
    if (!vehiculosDB || vehiculosDB.length !== vehiculosIds.length) {
      return new Response(JSON.stringify({
        error: "Vehículos inválidos o no pertenecen al cliente."
      }), {
        status: 404,
        headers
      });
    }
    const selected = vehiculosDB.map((v)=>({
        id_vehiculo: Number(v.id_vehiculo),
        placa: String(v.placa ?? ""),
        id_centro_costo: v.id_centro_costo == null ? null : Number(v.id_centro_costo),
        monto_asignado: v.monto_asignado == null ? null : Number(v.monto_asignado)
      }));
    // No permitir si pertenece a OTRO centro
    const conflict = selected.find((v)=>v.id_centro_costo != null && v.id_centro_costo !== Number(id_centro_costo));
    if (conflict) {
      return new Response(JSON.stringify({
        error: `El vehículo ${conflict.placa} pertenece a otro centro de costo.`,
        id_vehiculo: conflict.id_vehiculo,
        id_centro_actual: conflict.id_centro_costo
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       4) CONSUMOS (en bloque) de los vehículos seleccionados
          (Estados 1 y 2)
    ===================================================== */ const { data: consumosSel, error: consSelErr } = await supabase.from("cb_abastecimientos").select("id_vehiculo, total").in("id_vehiculo", vehiculosIds).in("id_estado", [
      1,
      2
    ]);
    if (consSelErr) {
      return new Response(JSON.stringify({
        error: consSelErr.message
      }), {
        status: 400,
        headers
      });
    }
    const consumoMapSel = new Map();
    for (const r of consumosSel ?? []){
      const idv = Number(r.id_vehiculo);
      const tot = Number(r.total ?? 0);
      consumoMapSel.set(idv, (consumoMapSel.get(idv) ?? 0) + tot);
    }
    /* =====================================================
       5) VALIDACIÓN CENTRO: simular comprometido FINAL del centro
          Comprometido vehiculo = monto_asignado si NO NULL,
          si NULL entonces consumo(1,2)
    ===================================================== */ // Vehículos actuales del centro (ids + monto)
    const { data: vehCentroActual, error: vcaErr } = await supabase.from("ms_vehiculos").select("id_vehiculo, monto_asignado").eq("id_cliente", id_cliente).eq("id_centro_costo", id_centro_costo);
    if (vcaErr) {
      return new Response(JSON.stringify({
        error: vcaErr.message
      }), {
        status: 400,
        headers
      });
    }
    const setFinalCentro = new Set();
    for (const v of vehCentroActual ?? [])setFinalCentro.add(Number(v.id_vehiculo));
    for (const v of selected)setFinalCentro.add(v.id_vehiculo);
    const finalCentroIds = Array.from(setFinalCentro);
    // Traer datos de monto_asignado de TODOS los que quedarán en el centro
    const { data: vehFinalCentroRows, error: vfcErr } = await supabase.from("ms_vehiculos").select("id_vehiculo, monto_asignado").eq("id_cliente", id_cliente).in("id_vehiculo", finalCentroIds);
    if (vfcErr) {
      return new Response(JSON.stringify({
        error: vfcErr.message
      }), {
        status: 400,
        headers
      });
    }
    // Consumos (en bloque) de los ids finales del centro
    const { data: consumosCentro, error: consCentroErr } = await supabase.from("cb_abastecimientos").select("id_vehiculo, total").in("id_vehiculo", finalCentroIds).in("id_estado", [
      1,
      2
    ]);
    if (consCentroErr) {
      return new Response(JSON.stringify({
        error: consCentroErr.message
      }), {
        status: 400,
        headers
      });
    }
    const consumoMapCentro = new Map();
    for (const r of consumosCentro ?? []){
      const idv = Number(r.id_vehiculo);
      const tot = Number(r.total ?? 0);
      consumoMapCentro.set(idv, (consumoMapCentro.get(idv) ?? 0) + tot);
    }
    let comprometidoFinalCentro = 0;
    for (const v of vehFinalCentroRows ?? []){
      const idv = Number(v.id_vehiculo);
      const montoV = v.monto_asignado;
      if (montoV != null) {
        comprometidoFinalCentro += Number(montoV);
      } else {
        comprometidoFinalCentro += consumoMapCentro.get(idv) ?? 0;
      }
    }
    if (comprometidoFinalCentro > montoCentro) {
      return new Response(JSON.stringify({
        error: `El centro "${centro.nombre}" no tiene saldo suficiente.`,
        monto_centro: montoCentro,
        comprometido_final: comprometidoFinalCentro,
        excedente: comprometidoFinalCentro - montoCentro
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       6) VALIDACIÓN GLOBAL CONTRA LÍNEA (modelo REAL)
          impacto = SUM(centros activos)
                 + SUM(vehículos SIN centro con monto)
                 + SUM(consumo vehículos SIN centro y SIN monto)
          y simular “DESPUÉS”:
            - si muevo vehículos desde sin centro → los saco del impacto global
    ===================================================== */ // Total centros activos (incluye este centro, no cambia por esta operación)
    const { data: centrosActivos, error: centrosErr } = await supabase.from("ms_centro_costo").select("monto_asignado").eq("id_cliente", id_cliente).eq("estado", true);
    if (centrosErr) {
      return new Response(JSON.stringify({
        error: centrosErr.message
      }), {
        status: 400,
        headers
      });
    }
    const totalCentrosActivos = centrosActivos?.reduce((s, c)=>s + Number(c.monto_asignado ?? 0), 0) ?? 0;
    // Vehículos SIN centro CON monto (estado actual)
    const { data: sinCentroConMonto, error: scmErr } = await supabase.from("ms_vehiculos").select("id_vehiculo, monto_asignado").eq("id_cliente", id_cliente).is("id_centro_costo", null).not("monto_asignado", "is", null);
    if (scmErr) {
      return new Response(JSON.stringify({
        error: scmErr.message
      }), {
        status: 400,
        headers
      });
    }
    const totalSinCentroConMontoActual = sinCentroConMonto?.reduce((s, v)=>s + Number(v.monto_asignado ?? 0), 0) ?? 0;
    // Consumo de vehículos SIN centro y SIN monto (estado actual)
    const { data: consumoSinMontoGlobalRows, error: csmgErr } = await supabase.from("cb_abastecimientos").select("total, ms_vehiculos!inner(id_cliente, id_centro_costo, monto_asignado)").eq("ms_vehiculos.id_cliente", id_cliente).is("ms_vehiculos.id_centro_costo", null).is("ms_vehiculos.monto_asignado", null).in("id_estado", [
      1,
      2
    ]);
    if (csmgErr) {
      return new Response(JSON.stringify({
        error: csmgErr.message
      }), {
        status: 400,
        headers
      });
    }
    const consumoSinMontoGlobalActual = consumoSinMontoGlobalRows?.reduce((s, r)=>s + Number(r.total ?? 0), 0) ?? 0;
    // ---- Simular “después”: sacar del global a los vehículos seleccionados si estaban sin centro ----
    let quitarSinCentroConMonto = 0;
    let quitarConsumoSinMonto = 0;
    for (const v of selected){
      const estabaSinCentro = v.id_centro_costo == null;
      if (!estabaSinCentro) continue;
      if (v.monto_asignado != null) {
        quitarSinCentroConMonto += Number(v.monto_asignado);
      } else {
        quitarConsumoSinMonto += consumoMapSel.get(v.id_vehiculo) ?? 0;
      }
    }
    const totalSinCentroConMontoAfter = totalSinCentroConMontoActual - quitarSinCentroConMonto;
    const consumoSinMontoGlobalAfter = consumoSinMontoGlobalActual - quitarConsumoSinMonto;
    const impactoAfter = totalCentrosActivos + totalSinCentroConMontoAfter + consumoSinMontoGlobalAfter;
    if (impactoAfter > topeLinea) {
      return new Response(JSON.stringify({
        error: "La operación excede el saldo global permitido por la línea.",
        tope_linea: topeLinea,
        impacto_after: impactoAfter,
        excedente: impactoAfter - topeLinea
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       7) UPDATE FINAL
    ===================================================== */ // ✅ AUDITORÍA: DATA BEFORE (vehículos antes de asignar)
    const { data: dataBefore } = await supabase.from("ms_vehiculos").select("*").eq("id_cliente", id_cliente).in("id_vehiculo", vehiculosIds);
    const { error: updErr } = await supabase.from("ms_vehiculos").update({
      id_centro_costo
    }).in("id_vehiculo", vehiculosIds);
    if (updErr) {
      return new Response(JSON.stringify({
        error: updErr.message
      }), {
        status: 400,
        headers
      });
    }
    // ✅ AUDITORÍA: DATA AFTER (vehículos después de asignar)
    const { data: dataAfter } = await supabase.from("ms_vehiculos").select("*").eq("id_cliente", id_cliente).in("id_vehiculo", vehiculosIds);
    // ✅ AUDITORÍA: INSERT
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_vehiculos",
      accion: "ASIGNAR_VEHICULOS_CENTRO",
      registro_id: vehiculosIds.join(","),
      data_before: dataBefore ?? null,
      data_after: dataAfter ?? null
    });
    return new Response(JSON.stringify({
      success: true,
      message: `Vehículos asignados correctamente al centro "${centro.nombre}".`,
      centro: {
        id_centro_costo,
        monto_centro: montoCentro,
        comprometido_final: comprometidoFinalCentro,
        disponible: montoCentro - comprometidoFinalCentro
      },
      linea: {
        tope_linea: topeLinea,
        impacto_after: impactoAfter,
        disponible: topeLinea - impactoAfter
      }
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
