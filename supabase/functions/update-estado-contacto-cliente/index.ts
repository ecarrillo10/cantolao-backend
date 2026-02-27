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
    const { uid_usuario, id_contacto, estado } = await req.json();
    if (!uid_usuario || !id_contacto || typeof estado !== "boolean") {
      return new Response(JSON.stringify({
        error: "Datos obligatorios incompletos."
      }), {
        status: 400,
        headers
      });
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* ================= VALIDAR CONTACTO EXISTE ================= */ const { data: contactoActual } = await supabase.from("ms_contactos_cliente").select("estado").eq("id_contacto", id_contacto).maybeSingle();
    if (!contactoActual) {
      return new Response(JSON.stringify({
        error: "Contacto no encontrado."
      }), {
        status: 404,
        headers
      });
    }
    /* ================= UPDATE SOLO ESTADO ================= */ const { error: updateError } = await supabase.from("ms_contactos_cliente").update({
      estado
    }).eq("id_contacto", id_contacto);
    if (updateError) {
      return new Response(JSON.stringify({
        error: "Error al actualizar el estado del contacto."
      }), {
        status: 500,
        headers
      });
    }
    /* ================= AUDITORÍA ================= */ const { error: auditError } = await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_contactos_cliente",
      accion: "UPDATE_ESTADO_CONTACTO",
      registro_id: String(id_contacto),
      data_before: {
        estado: contactoActual.estado
      },
      data_after: {
        estado
      }
    });
    if (auditError) console.error("AUDITORIA ERROR:", auditError);
    return new Response(JSON.stringify({
      success: true,
      message: "Estado del contacto actualizado correctamente."
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
