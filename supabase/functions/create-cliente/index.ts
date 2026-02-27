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
        error: "Método no permitido"
      }), {
        status: 405,
        headers
      });
    }
    const { uid_usuario, ruc, razon_social, direccion, telefono, estado = true } = await req.json();
    if (!uid_usuario || !ruc || !razon_social) {
      return new Response(JSON.stringify({
        error: "Completa los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    if (!/^\d{11}$/.test(ruc)) {
      return new Response(JSON.stringify({
        error: "El RUC debe tener 11 dígitos numéricos."
      }), {
        status: 400,
        headers
      });
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    const { data: rucExiste } = await supabase.from("ms_clientes").select("id_cliente").eq("ruc", ruc).maybeSingle();
    if (rucExiste) {
      return new Response(JSON.stringify({
        error: "Este RUC ya se encuentra registrado."
      }), {
        status: 409,
        headers
      });
    }
    // ✅ IMPORTANTE: devolver id_cliente para auditar bien
    const { data: clienteCreado, error: insertError } = await supabase.from("ms_clientes").insert({
      ruc,
      razon_social,
      direccion,
      telefono,
      estado
    }).select("id_cliente, ruc, razon_social, direccion, telefono, estado").single();
    if (insertError || !clienteCreado) {
      return new Response(JSON.stringify({
        error: "No se pudo registrar el cliente. Inténtalo más tarde."
      }), {
        status: 500,
        headers
      });
    }
    // ✅ registro_id = PK real (id_cliente)
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_clientes",
      accion: "INSERT_CLIENTE",
      registro_id: String(clienteCreado.id_cliente),
      data_before: null,
      data_after: clienteCreado
    });
    return new Response(JSON.stringify({
      success: true,
      message: "Cliente registrado correctamente."
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({
      error: "Ocurrió un error inesperado. Inténtalo más tarde."
    }), {
      status: 500,
      headers
    });
  }
});
