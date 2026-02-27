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
    /* =====================================================
       1️⃣ BODY
    ===================================================== */ const { uid_usuario, id_cliente, ruc, razon_social, direccion, telefono } = await req.json();
    if (!uid_usuario || !id_cliente || !ruc || !razon_social) {
      return new Response(JSON.stringify({
        error: "Completa los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       2️⃣ VALIDAR RUC
    ===================================================== */ if (!/^\d{11}$/.test(ruc)) {
      return new Response(JSON.stringify({
        error: "El RUC debe tener 11 dígitos numéricos."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       3️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       4️⃣ VALIDAR CLIENTE EXISTE
    ===================================================== */ const { data: clienteActual, error: clienteError } = await supabase.from("ms_clientes").select("*").eq("id_cliente", id_cliente).maybeSingle();
    if (clienteError || !clienteActual) {
      return new Response(JSON.stringify({
        error: "El cliente que intentas editar no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       5️⃣ VALIDAR RUC ÚNICO (SI CAMBIÓ)
    ===================================================== */ if (ruc !== clienteActual.ruc) {
      const { data: rucExiste } = await supabase.from("ms_clientes").select("id_cliente").eq("ruc", ruc).neq("id_cliente", id_cliente).maybeSingle();
      if (rucExiste) {
        return new Response(JSON.stringify({
          error: "Este RUC ya se encuentra registrado."
        }), {
          status: 409,
          headers
        });
      }
    }
    /* =====================================================
       6️⃣ ACTUALIZAR CLIENTE
    ===================================================== */ const { error: updateError } = await supabase.from("ms_clientes").update({
      ruc,
      razon_social,
      direccion,
      telefono
    }).eq("id_cliente", id_cliente);
    if (updateError) {
      return new Response(JSON.stringify({
        error: "Ocurrió un error al actualizar la información del cliente."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       ✅ AUDITORÍA (ROBUSTA)
    ===================================================== */ const dataAfter = {
      ...clienteActual,
      ruc,
      razon_social,
      direccion,
      telefono
    };
    const { error: auditError } = await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_clientes",
      accion: "UPDATE_CLIENTE",
      registro_id: String(id_cliente),
      data_before: clienteActual,
      data_after: dataAfter
    });
    // ⚠️ Si auditoría falla, NO rompemos el flujo
    if (auditError) {
      console.error("AUDITORIA ERROR:", auditError);
    }
    /* =====================================================
       7️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "La información del cliente se actualizó correctamente."
    }), {
      status: 200,
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
