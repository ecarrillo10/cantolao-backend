import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  // =====================================================
  // CORS (PATRÓN ESTABLE – PROYECTO ANTERIOR)
  // =====================================================
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type"
  };
  // Preflight
  if (req.method === "OPTIONS") {
    return new Response(JSON.stringify({
      ok: true
    }), {
      status: 200,
      headers
    });
  }
  try {
    // =====================================================
    // SOLO POST
    // =====================================================
    if (req.method !== "POST") {
      return new Response(JSON.stringify({
        error: "Método no permitido."
      }), {
        status: 405,
        headers
      });
    }
    /* =====================================================
       1️⃣ BODY
    ===================================================== */ const { id_cliente, id_contacto } = await req.json();
    if (!id_cliente || !id_contacto) {
      return new Response(JSON.stringify({
        error: "Información incompleta. Selecciona un contacto válido."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       2️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       3️⃣ VALIDAR CONTACTO DEL CLIENTE
    ===================================================== */ const { data: contacto } = await supabase.from("ms_contactos_cliente").select("id_contacto").eq("id_contacto", id_contacto).eq("id_cliente", id_cliente).maybeSingle();
    if (!contacto) {
      return new Response(JSON.stringify({
        error: "El contacto no pertenece a este cliente."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       4️⃣ RESET CONTACTOS
    ===================================================== */ const { error: resetError } = await supabase.from("ms_contactos_cliente").update({
      contactoPrincipal: false
    }).eq("id_cliente", id_cliente);
    if (resetError) {
      return new Response(JSON.stringify({
        error: "No se pudo actualizar los contactos del cliente."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       5️⃣ SET CONTACTO PRINCIPAL
    ===================================================== */ const { error: setError } = await supabase.from("ms_contactos_cliente").update({
      contactoPrincipal: true
    }).eq("id_contacto", id_contacto);
    if (setError) {
      return new Response(JSON.stringify({
        error: "No se pudo establecer el contacto principal."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       6️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Contacto principal actualizado correctamente."
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "Ocurrió un error inesperado. Inténtalo más tarde."
    }), {
      status: 500,
      headers
    });
  }
});
