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
    const { uid_usuario, id_cliente, estado } = await req.json();
    if (!uid_usuario || !id_cliente || typeof estado !== "boolean") {
      return new Response(JSON.stringify({
        error: "Datos obligatorios incompletos."
      }), {
        status: 400,
        headers
      });
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* ================= VALIDAR EXISTE ================= */ const { data: clienteActual } = await supabase.from("ms_clientes").select("*").eq("id_cliente", id_cliente).maybeSingle();
    if (!clienteActual) {
      return new Response(JSON.stringify({
        error: "Cliente no encontrado."
      }), {
        status: 404,
        headers
      });
    }
    /* ================= UPDATE SOLO ESTADO ================= */ const { error: updateError } = await supabase.from("ms_clientes").update({
      estado
    }).eq("id_cliente", id_cliente);
    if (updateError) {
      return new Response(JSON.stringify({
        error: "Error al actualizar el estado."
      }), {
        status: 500,
        headers
      });
    }
    /* ================= AUDITORÍA ================= */ const { error: auditError } = await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_clientes",
      accion: "UPDATE_ESTADO_CLIENTE",
      registro_id: String(id_cliente),
      data_before: {
        estado: clienteActual.estado
      },
      data_after: {
        estado
      }
    });
    if (auditError) console.error("AUDITORIA:", auditError);
    return new Response(JSON.stringify({
      success: true,
      message: "Estado del cliente actualizado correctamente."
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
