import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
serve(async (req)=>{
  // =====================================================
  // CORS (MISMO PATRÓN QUE PROYECTO ANTERIOR)
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
  // =====================================================
  // SOLO POST
  // =====================================================
  if (req.method !== "POST") {
    return new Response(JSON.stringify({
      error: "Método no permitido"
    }), {
      status: 405,
      headers
    });
  }
  // =====================================================
  // VALIDAR JWT (MISMA LÓGICA)
  // =====================================================
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return new Response(JSON.stringify({
      error: "No autorizado"
    }), {
      status: 401,
      headers
    });
  }
  // =====================================================
  // BODY
  // =====================================================
  let body;
  try {
    body = await req.json();
  } catch  {
    return new Response(JSON.stringify({
      error: "Body inválido"
    }), {
      status: 400,
      headers
    });
  }
  const { ruc } = body;
  if (!ruc || typeof ruc !== "string" || ruc.length !== 11) {
    return new Response(JSON.stringify({
      error: "RUC inválido"
    }), {
      status: 400,
      headers
    });
  }
  // =====================================================
  // LLAMADA A APIPERU
  // =====================================================
  try {
    const response = await fetch("https://apiperu.dev/api/ruc", {
      method: "POST",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": `Bearer ${Deno.env.get("APIPERU_TOKEN")}`
      },
      body: JSON.stringify({
        ruc
      })
    });
    const data = await response.json();
    if (!response.ok) {
      console.error("apiperu error:", data);
      return new Response(JSON.stringify({
        success: false,
        error: "Error al consultar RUC, inténtelo nuevamente o ingrese los datos manualmente",
        details: data
      }), {
        status: 502,
        headers
      });
    }
    // =====================================================
    // RESPUESTA FINAL (201 + JSON)
    // =====================================================
    return new Response(JSON.stringify({
      success: true,
      data: data.data ?? data
    }), {
      status: 201,
      headers
    });
  } catch (err) {
    console.error("fetch error:", err);
    return new Response(JSON.stringify({
      success: false,
      error: "Error interno del servidor"
    }), {
      status: 500,
      headers
    });
  }
});
