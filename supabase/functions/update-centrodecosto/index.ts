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
    /* ================= BODY COMPLETO OBLIGATORIO ================= */ const { uid_usuario, id_cliente, id_centro_costo, nombre, estado } = await req.json();
    if (!uid_usuario || !id_cliente || !id_centro_costo || typeof nombre !== "string" || typeof estado !== "boolean") {
      return new Response(JSON.stringify({
        error: "Debe enviar uid_usuario, id_cliente, id_centro_costo, nombre y estado."
      }), {
        status: 400,
        headers
      });
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* ================= CENTRO ================= */ const { data: centro } = await supabase.from("ms_centro_costo").select("*").eq("id_centro_costo", id_centro_costo).eq("id_cliente", id_cliente).maybeSingle();
    if (!centro) {
      return new Response(JSON.stringify({
        error: "Centro de costo no encontrado."
      }), {
        status: 404,
        headers
      });
    }
    /* ================= SI SE DESACTIVA ================= */ if (estado === false && centro.estado === true) {
      // 🔹 quitar centro a vehículos
      await supabase.from("ms_vehiculos").update({
        id_centro_costo: null
      }).eq("id_centro_costo", id_centro_costo);
      // 🔹 poner monto null
      await supabase.from("ms_centro_costo").update({
        monto_asignado: null
      }).eq("id_centro_costo", id_centro_costo);
    }
    /* ================= UPDATE ================= */ const dataAfter = {
      ...centro,
      nombre,
      estado
    };
    const { error: updateError } = await supabase.from("ms_centro_costo").update({
      nombre,
      estado
    }).eq("id_centro_costo", id_centro_costo);
    if (updateError) {
      return new Response(JSON.stringify({
        error: updateError.message
      }), {
        status: 500,
        headers
      });
    }
    /* ================= AUDITORIA ================= */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_centro_costo",
      accion: "UPDATE_CENTRO_COSTO",
      registro_id: String(id_centro_costo),
      data_before: centro,
      data_after: dataAfter
    });
    return new Response(JSON.stringify({
      success: true,
      message: "Centro de costo actualizado correctamente."
    }), {
      status: 200,
      headers
    });
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({
      error: "Error inesperado.",
      detalle: error.message
    }), {
      status: 500,
      headers
    });
  }
});
