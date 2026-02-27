import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import ExcelJS from "https://esm.sh/exceljs@4.4.0";
/* ================= CONFIG ================= */ const BUCKET = "Documentos";
const FOLDER = "Reportes/Global";
const SHEET_NAME = "Reporte Global Abastecimientos";
/* ================= UTILIDADES ================= */ function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type"
  };
}
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders()
    }
  });
}
function thinBorder() {
  return {
    top: {
      style: "thin"
    },
    left: {
      style: "thin"
    },
    bottom: {
      style: "thin"
    },
    right: {
      style: "thin"
    }
  };
}
function autoFitColumns(ws, colCount) {
  for(let i = 1; i <= colCount; i++){
    let max = 12;
    ws.eachRow({
      includeEmpty: true
    }, (row)=>{
      const val = row.getCell(i).value ?? "";
      max = Math.max(max, String(val).length);
    });
    ws.getColumn(i).width = Math.min(Math.max(max + 2, 14), 45);
  }
}
// 🔥 FORMATO 120226_160713
function nowLimaCompact() {
  const p = new Intl.DateTimeFormat("es-PE", {
    timeZone: "America/Lima",
    year: "2-digit",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false
  }).formatToParts(new Date()).reduce((a, t)=>{
    if (t.type !== "literal") a[t.type] = t.value;
    return a;
  }, {});
  return `${p.day}${p.month}${p.year}_${p.hour}${p.minute}${p.second}`;
}
/* ================= SERVER ================= */ serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response(null, {
    headers: corsHeaders()
  });
  try {
    if (req.method !== "POST") return json({
      error: "Use POST"
    }, 405);
    const sbSR = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    const body = await req.json();
    const idCliente = body.id_cliente ? Number(body.id_cliente) : null;
    const idEstacion = body.id_estacion ? Number(body.id_estacion) : null;
    const idZona = body.id_zona ? Number(body.id_zona) : null;
    const idCombustible = body.id_combustible ? Number(body.id_combustible) : null;
    const fechaInicio = body.fecha_inicio || null;
    const fechaFin = body.fecha_fin || null;
    /* ---------- Query dinámica ---------- */ let q = sbSR.from("vw_reporteglobal_abastecimientos").select("*").order("fecha", {
      ascending: false
    });
    if (idCliente) q = q.eq("id_cliente", idCliente);
    if (idEstacion) q = q.eq("id_estacion", idEstacion);
    if (idZona) q = q.eq("id_zona", idZona);
    if (idCombustible) q = q.eq("id_combustible", idCombustible);
    if (fechaInicio && fechaFin) {
      q = q.gte("fecha", fechaInicio).lt("fecha", fechaFin); // fechaFin ya viene +1
    }
    // 🔥 IMPORTANTE: traer todos los registros
    const { data, error } = await q;
    if (error) return json({
      error: error.message
    }, 400);
    if (!data || !data.length) return json({
      error: "No existen registros para exportar"
    }, 404);
    /* ---------- Excel ---------- */ const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet(SHEET_NAME);
    const headers = [
      "Fecha",
      "Cliente",
      "Estación",
      "Zona",
      "Combustible",
      "Galones",
      "Precio/Gal",
      "Monto",
      "Consumos"
    ];
    ws.addRow(headers);
    ws.getRow(1).font = {
      bold: true
    };
    ws.getRow(1).eachCell((c)=>c.border = thinBorder());
    data.forEach((r)=>{
      const row = ws.addRow([
        new Date(r.fecha),
        r.cliente,
        r.estacion,
        r.zona,
        r.combustible,
        Number(r.galones),
        Number(r.precio_gal),
        Number(r.monto),
        Number(r.tickets)
      ]);
      row.eachCell((c)=>c.border = thinBorder());
    });
    ws.getColumn(1).numFmt = "dd/mm/yyyy";
    ws.getColumn(6).numFmt = "#,##0.00";
    ws.getColumn(7).numFmt = "#,##0.00";
    ws.getColumn(8).numFmt = '"S/ " #,##0.00';
    autoFitColumns(ws, headers.length);
    const fileName = `Reporte_Global_Abastecimientos_${nowLimaCompact()}.xlsx`;
    const buffer = await wb.xlsx.writeBuffer();
    const { error: uploadError } = await sbSR.storage.from(BUCKET).upload(`${FOLDER}/${fileName}`, buffer, {
      contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      upsert: true
    });
    if (uploadError) return json({
      error: uploadError.message
    }, 500);
    const { data: pub } = sbSR.storage.from(BUCKET).getPublicUrl(`${FOLDER}/${fileName}`);
    return json({
      success: true,
      fileName,
      url: pub.publicUrl
    });
  } catch (e) {
    return json({
      error: e.message
    }, 500);
  }
});
