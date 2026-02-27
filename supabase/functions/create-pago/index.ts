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
    ===================================================== */ const { uid_usuario, abastecimientos_ids// array requerido
     } = await req.json();
    if (!uid_usuario || !abastecimientos_ids || !Array.isArray(abastecimientos_ids) || abastecimientos_ids.length === 0) {
      return new Response(JSON.stringify({
        error: "Debe enviar uid_usuario y array de IDs."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       2️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       3️⃣ DATA BEFORE (auditoría)
    ===================================================== */ const { data: beforeRows, error: beforeError } = await supabase.from("cb_abastecimientos").select("*").in("id_abastecimiento", abastecimientos_ids);
    if (beforeError) {
      return new Response(JSON.stringify({
        error: "Error al obtener datos previos.",
        detalle: beforeError.message
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       4️⃣ UPDATE MASIVO
       - estado = 3
       - fecha_pago = hoy (servidor)
    ===================================================== */ const fechaPago = new Date().toISOString(); // timestamp with time zone
    const { data: updated, error } = await supabase.from("cb_abastecimientos").update({
      id_estado: 3,
      fecha_pago: fechaPago
    }).in("id_abastecimiento", abastecimientos_ids).select();
    if (error) {
      return new Response(JSON.stringify({
        error: "Error al actualizar abastecimientos.",
        detalle: error.message
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       📘 AUDITORÍA
    ===================================================== */ if (updated && updated.length > 0) {
      const auditoriaRows = updated.map((row)=>({
          usuario: uid_usuario,
          tabla_afectada: "cb_abastecimientos",
          accion: "UPDATE_ESTADO_3_CON_PAGO",
          registro_id: String(row.id_abastecimiento),
          data_before: beforeRows?.find((b)=>b.id_abastecimiento === row.id_abastecimiento) ?? null,
          data_after: row
        }));
      await supabase.from("auditoria").insert(auditoriaRows);
    }
    /* =====================================================
       5️⃣ RESPUESTA
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Abastecimientos marcados como pagados correctamente.",
      fecha_pago: fechaPago,
      total_actualizados: updated?.length ?? 0,
      ids: abastecimientos_ids
    }), {
      status: 200,
      headers
    });
  } catch (err) {
    return new Response(JSON.stringify({
      error: "Error inesperado.",
      detalle: err?.message ?? err
    }), {
      status: 500,
      headers
    });
  }
});
