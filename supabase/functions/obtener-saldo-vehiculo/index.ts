// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
Deno.serve(async (req)=>{
  // =============================
  // CORS
  // =============================
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, apikey, x-client-info",
    "Access-Control-Max-Age": "86400"
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
        estado: "ERROR",
        mensaje: "Método no permitido"
      }), {
        status: 405,
        headers
      });
    }
    const body = await req.json();
    const { id_vehiculo } = body;
    if (!id_vehiculo) {
      return new Response(JSON.stringify({
        estado: "ERROR",
        mensaje: "id_vehiculo es requerido"
      }), {
        status: 400,
        headers
      });
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    const { data, error } = await supabase.rpc("fn_saldo_disponible_vehiculo", {
      p_id_vehiculo: id_vehiculo
    });
    if (error) {
      return new Response(JSON.stringify({
        estado: "ERROR",
        mensaje: error.message
      }), {
        status: 400,
        headers
      });
    }
    return new Response(JSON.stringify({
      estado: "OK",
      saldo_disponible: data
    }), {
      status: 200,
      headers
    });
  } catch (err) {
    return new Response(JSON.stringify({
      estado: "ERROR",
      mensaje: err.message ?? "Error inesperado"
    }), {
      status: 500,
      headers
    });
  }
});
