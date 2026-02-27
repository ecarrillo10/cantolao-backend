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
    /* ================= LÍNEA ACTIVA ================= */ const { data: linea } = await supabase.from("cb_lineas").select("monto_asignado").eq("id_cliente", id_cliente).eq("estado", true).maybeSingle();
    if (!linea) {
      return new Response(JSON.stringify({
        error: "El cliente no tiene una línea activa."
      }), {
        status: 409,
        headers
      });
    }
    /* ================= CENTRO DE COSTO (DATA BEFORE) ================= */ const { data: centro } = await supabase.from("ms_centro_costo").select("*").eq("id_centro_costo", id_centro_costo).eq("id_cliente", id_cliente).maybeSingle();
    if (!centro) {
      return new Response(JSON.stringify({
        error: "Centro de costo no encontrado."
      }), {
        status: 404,
        headers
      });
    }
    if (!centro.estado) {
      return new Response(JSON.stringify({
        error: "El centro de costo está inactivo."
      }), {
        status: 409,
        headers
      });
    }
    /* ================= VEHÍCULOS DEL CENTRO ================= */ const { data: vehiculosCentro } = await supabase.from("ms_vehiculos").select("monto_asignado").eq("id_centro_costo", id_centro_costo).eq("id_cliente", id_cliente);
    const totalVehiculos = (vehiculosCentro ?? []).reduce((acc, v)=>acc + Number(v.monto_asignado ?? 0), 0);
    if (nuevoMonto < totalVehiculos) {
      return new Response(JSON.stringify({
        error: `El monto del centro de costo es menor al total asignado a sus vehículos (${totalVehiculos}).`
      }), {
        status: 409,
        headers
      });
    }
    /* ================= VALIDAR CONTRA LÍNEA ================= */ const { data: centros } = await supabase.from("ms_centro_costo").select("id_centro_costo, monto_asignado").eq("id_cliente", id_cliente).eq("estado", true);
    const totalOtrosCentros = (centros ?? []).filter((c)=>c.id_centro_costo !== id_centro_costo).reduce((a, c)=>a + Number(c.monto_asignado ?? 0), 0);
    const { data: vehiculosSinCentro } = await supabase.from("ms_vehiculos").select("monto_asignado").eq("id_cliente", id_cliente).is("id_centro_costo", null);
    const totalSinCentro = (vehiculosSinCentro ?? []).reduce((a, v)=>a + Number(v.monto_asignado ?? 0), 0);
    if (totalOtrosCentros + totalSinCentro + nuevoMonto > Number(linea.monto_asignado)) {
      return new Response(JSON.stringify({
        error: "El monto del centro de costo excede el saldo total de la línea."
      }), {
        status: 409,
        headers
      });
    }
    /* ================= UPDATE ================= */ await supabase.from("ms_centro_costo").update({
      monto_asignado: nuevoMonto
    }).eq("id_centro_costo", id_centro_costo);
    /* ================= AUDITORÍA ================= */ const dataAfter = {
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
      message: `Monto del centro de costo ${centro.nombre} actualizado correctamente.`
    }), {
      status: 200,
      headers
    });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({
      error: "Error inesperado."
    }), {
      status: 500,
      headers
    });
  }
});
