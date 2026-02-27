import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  // ================================
  // CORS
  // ================================
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
        error: "Solo se permite POST."
      }), {
        status: 405,
        headers
      });
    }
    // Leer body (galones es opcional: si lo envías, también valida)
    const { id_cliente, id_combustible, id_estacion, id_vehiculo, galones } = await req.json();
    // Validación de campos obligatorios
    if (id_cliente == null || id_combustible == null || id_estacion == null || id_vehiculo == null) {
      return new Response(JSON.stringify({
        error: "Parámetros incompletos"
      }), {
        status: 400,
        headers
      });
    }
    // Normalizar a número
    const nIdCliente = Number(id_cliente);
    const nIdComb = Number(id_combustible);
    const nIdEst = Number(id_estacion);
    const nIdVeh = Number(id_vehiculo);
    if (!Number.isFinite(nIdCliente) || !Number.isFinite(nIdComb) || !Number.isFinite(nIdEst) || !Number.isFinite(nIdVeh) || nIdCliente <= 0 || nIdComb <= 0 || nIdEst <= 0 || nIdVeh <= 0) {
      return new Response(JSON.stringify({
        error: "IDs inválidos (deben ser numéricos > 0)."
      }), {
        status: 400,
        headers
      });
    }
    // Si mandan galones, validar que sea número > 0
    const nGalones = galones == null ? null : Number(galones);
    if (nGalones !== null) {
      if (!Number.isFinite(nGalones) || nGalones <= 0) {
        return new Response(JSON.stringify({
          error: "galones inválido (debe ser numérico > 0)."
        }), {
          status: 400,
          headers
        });
      }
    }
    // Cliente Supabase (anon + JWT del usuario)
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_ANON_KEY"), {
      global: {
        headers: {
          Authorization: req.headers.get("Authorization") ?? ""
        }
      }
    });
    // ===== 1) SALDO (tu RPC ya valida línea/centro/vehículo + estados 1,2)
    const { data: saldoData, error: saldoError } = await supabase.rpc("fn_saldo_disponible_vehiculo", {
      p_id_vehiculo: nIdVeh
    });
    if (saldoError) {
      return new Response(JSON.stringify({
        ok: false,
        code: "RPC_ERROR_SALDO",
        message: saldoError.message
      }), {
        status: 400,
        headers
      });
    }
    const saldo_disponible = Array.isArray(saldoData) ? Number(saldoData?.[0]?.saldo_disponible ?? saldoData?.[0]?.saldo ?? 0) : Number(saldoData ?? 0);
    if (!Number.isFinite(saldo_disponible) || saldo_disponible < 0) {
      return new Response(JSON.stringify({
        ok: false,
        code: "SALDO_INVALIDO",
        message: "Saldo disponible inválido."
      }), {
        status: 409,
        headers
      });
    }
    // ===== 2) PRECIO VIGENTE REAL (con fecha_fin)
    const nowIso = new Date().toISOString();
    const { data: precioRows, error: precioError } = await supabase.from("cb_precios_combustible").select("precio, fecha_inicio, fecha_fin, estado").eq("id_combustible", nIdComb).eq("id_cliente", nIdCliente).eq("id_estacion", nIdEst).eq("estado", true).lte("fecha_inicio", nowIso).order("fecha_inicio", {
      ascending: false
    }).limit(10);
    if (precioError) {
      return new Response(JSON.stringify({
        ok: false,
        code: "DB_ERROR_PRECIO",
        message: precioError.message
      }), {
        status: 400,
        headers
      });
    }
    const vigente = (precioRows ?? []).find((p)=>{
      if (!p?.precio) return false;
      if (!p?.fecha_fin) return true;
      return new Date(p.fecha_fin).getTime() >= Date.now();
    });
    const precio = Number(vigente?.precio ?? 0);
    if (!vigente || !Number.isFinite(precio) || precio <= 0) {
      return new Response(JSON.stringify({
        ok: false,
        code: "NO_PRECIO_VIGENTE",
        message: "No existe precio vigente válido para el combustible/cliente/estación seleccionados.",
        data: null
      }), {
        status: 200,
        headers
      });
    }
    // ===== 3) CÁLCULO GALONES MÁXIMOS (en base a saldo real + precio vigente)
    const round3 = (n)=>Math.round(n * 1000) / 1000;
    // Si saldo es 0, galones max es 0.
    const galones_maximos = saldo_disponible <= 0 ? 0 : round3(saldo_disponible / precio);
    // ===== 4) VALIDACIÓN EXTRA (si el cliente manda galones)
    // Esto evita “solo calcular” y pasa a “validar”, incluso si la línea se redujo.
    if (nGalones !== null) {
      const total_estimado = Number((nGalones * precio).toFixed(2));
      if (total_estimado > saldo_disponible) {
        return new Response(JSON.stringify({
          ok: false,
          code: "INSUFFICIENT_FUNDS",
          message: "Saldo insuficiente para los galones solicitados.",
          data: {
            saldo_disponible,
            precio,
            galones_solicitados: nGalones,
            total_estimado,
            galones_maximos
          }
        }), {
          status: 409,
          headers
        });
      }
    }
    return new Response(JSON.stringify({
      ok: true,
      data: {
        saldo_disponible,
        precio,
        galones_maximos,
        ...nGalones !== null ? {
          galones_solicitados: nGalones,
          total_estimado: Number((nGalones * precio).toFixed(2)),
          valid: true
        } : {}
      }
    }), {
      status: 200,
      headers
    });
  } catch (e) {
    return new Response(JSON.stringify({
      error: String(e)
    }), {
      status: 500,
      headers
    });
  }
});
