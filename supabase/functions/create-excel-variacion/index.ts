import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as XLSX from "https://esm.sh/xlsx@0.18.5?target=deno";
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
        error: "Método no permitido"
      }), {
        status: 405,
        headers
      });
    }
    /* =====================================================
       1️⃣ Validar sesión
    ===================================================== */ const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({
        error: "Sesión no válida o expirada"
      }), {
        status: 401,
        headers
      });
    }
    /* =====================================================
       2️⃣ Cliente Supabase (SERVICE ROLE)
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       3️⃣ Obtener zonas (SIN estado)
    ===================================================== */ const { data: zonas, error: zonasError } = await supabase.from("ms_zonas").select("id_zona, nombre").neq("nombre", "NO APLICA");
    if (zonasError || !zonas?.length) {
      return new Response(JSON.stringify({
        error: "No se pudieron obtener las zonas",
        detalle: zonasError?.message ?? "Sin registros"
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       4️⃣ Obtener combustibles
    ===================================================== */ const { data: combustibles, error: combustiblesError } = await supabase.from("ms_combustibles").select("id_combustible, nombre");
    if (combustiblesError || !combustibles?.length) {
      return new Response(JSON.stringify({
        error: "No se pudieron obtener los combustibles",
        detalle: combustiblesError?.message ?? "Sin registros"
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       5️⃣ Construir filas del Excel
    ===================================================== */ const rows = [];
    for (const zona of zonas){
      for (const comb of combustibles){
        rows.push({
          id_zona: zona.id_zona,
          zona: zona.nombre,
          id_combustible: comb.id_combustible,
          combustible: comb.nombre,
          variacion: 0
        });
      }
    }
    /* =====================================================
       6️⃣ Crear Excel
    ===================================================== */ const worksheet = XLSX.utils.json_to_sheet(rows);
    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, worksheet, "Modelo_Variacion_Precios");
    // ✅ FIX DEFINITIVO
    const excelArrayBuffer = XLSX.write(workbook, {
      type: "array",
      bookType: "xlsx"
    });
    const excelBuffer = new Uint8Array(excelArrayBuffer);
    /* =====================================================
       7️⃣ Nombre único
    ===================================================== */ const codigoUnico = Math.floor(100000 + Math.random() * 900000);
    const nombreArchivo = `formato_precios_${codigoUnico}.xlsx`;
    const rutaArchivo = `Excels/${nombreArchivo}`;
    /* =====================================================
       8️⃣ Subir a Storage
    ===================================================== */ const { error: uploadError } = await supabase.storage.from("Documentos").upload(rutaArchivo, excelBuffer, {
      contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      upsert: false
    });
    if (uploadError) {
      return new Response(JSON.stringify({
        error: "No se pudo subir el archivo Excel",
        detalle: uploadError.message
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       9️⃣ URL firmada
    ===================================================== */ const { data: signedUrl, error: urlError } = await supabase.storage.from("Documentos").createSignedUrl(rutaArchivo, 60 * 60); // 1 hora
    if (urlError || !signedUrl?.signedUrl) {
      return new Response(JSON.stringify({
        error: "No se pudo generar la URL del archivo",
        detalle: urlError?.message
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       🔟 RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      nombre_archivo: nombreArchivo,
      url: signedUrl.signedUrl
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "No se pudo generar el archivo Excel",
      detalle: error.message
    }), {
      status: 500,
      headers
    });
  }
});
