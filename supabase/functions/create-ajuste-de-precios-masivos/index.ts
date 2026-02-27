import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as XLSX from "https://esm.sh/xlsx@0.18.5";
serve(async (req)=>{
  // =====================================================
  // CORS
  // =====================================================
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
    /* =====================================================
       BODY
    ===================================================== */ const { excel_url, uid_usuario } = await req.json();
    if (!excel_url) {
      return new Response(JSON.stringify({
        error: "Debes enviar el enlace del archivo Excel."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       DESCARGAR EXCEL
    ===================================================== */ const excelResponse = await fetch(excel_url);
    if (!excelResponse.ok) {
      return new Response(JSON.stringify({
        error: "No se pudo descargar el archivo Excel."
      }), {
        status: 400,
        headers
      });
    }
    const buffer = await excelResponse.arrayBuffer();
    const workbook = XLSX.read(buffer, {
      type: "array"
    });
    const sheetName = workbook.SheetNames[0];
    const sheet = workbook.Sheets[sheetName];
    /* =====================================================
       LEER EXCEL (CLAVE DEL FIX)
    ===================================================== */ const filasRaw = XLSX.utils.sheet_to_json(sheet, {
      raw: true,
      defval: 0
    });
    if (!filasRaw.length) {
      return new Response(JSON.stringify({
        error: "El archivo Excel no contiene registros."
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       NORMALIZAR + VALIDAR
    ===================================================== */ const filasInvalidas = [];
    const filasLimpias = [];
    for(let i = 0; i < filasRaw.length; i++){
      const fila = filasRaw[i];
      const id_zona = Number(fila.id_zona);
      const id_combustible = Number(fila.id_combustible);
      const variacion = Number(fila.variacion); // 👈 AQUÍ SE ARREGLA "20"
      if (!Number.isFinite(id_zona) || !Number.isFinite(id_combustible) || !Number.isFinite(variacion)) {
        filasInvalidas.push(i + 2); // Excel empieza en fila 2
        continue;
      }
      filasLimpias.push({
        id_zona,
        id_combustible,
        variacion
      });
    }
    if (filasInvalidas.length > 0) {
      return new Response(JSON.stringify({
        error: "Formato de Excel inválido",
        filas: filasInvalidas.join(", ")
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       RPC MASIVA
    ===================================================== */ const { data, error } = await supabase.rpc("fn_ajuste_masivo_precios_excel", {
      p_filas: filasLimpias
    });
    if (error) {
      return new Response(JSON.stringify({
        error: "Proceso cancelado. No se aplicaron cambios.",
        detalle: error.message
      }), {
        status: 400,
        headers
      });
    }
    /* =====================================================
       ✅ AUDITORÍA (SOLO SI TODO SALIÓ OK)
       - No cambia tu lógica.
       - Si falla auditoría, NO rompe el proceso.
    ===================================================== */ try {
      await supabase.from("auditoria").insert({
        usuario: uid_usuario ?? null,
        tabla_afectada: "cb_precios_combustible",
        accion: "AJUSTE_MASIVO_PRECIOS_EXCEL",
        registro_id: String(excel_url),
        data_before: null,
        data_after: {
          excel_url,
          registros: filasLimpias.length,
          filas: filasLimpias,
          resultado: data
        }
      });
    } catch (auditErr) {
      console.warn("AUDITORIA NO REGISTRADA:", auditErr);
    // No interrumpimos el flujo
    }
    /* =====================================================
       RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Ajuste masivo aplicado correctamente.",
      registros: filasLimpias.length,
      resultado: data
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({
      error: "Error inesperado al procesar el archivo Excel.",
      detalle: error.message
    }), {
      status: 500,
      headers
    });
  }
});
