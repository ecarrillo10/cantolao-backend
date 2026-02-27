import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import ExcelJS from "https://esm.sh/exceljs@4.4.0";
/* ================= CONFIG ================= */ const BUCKET = "Documentos";
const FOLDER = "Reportes/Historial";
const SHEET_NAME = "Historial de Abastecimientos";
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
function toLimaDateForExcel(dateStr) {
  return new Date(new Date(dateStr).toLocaleString("en-US", {
    timeZone: "America/Lima"
  }));
}
/* ================= SERVER ================= */ serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response(null, {
    headers: corsHeaders()
  });
  try {
    if (req.method !== "POST") return json({
      error: "Use POST"
    }, 405);
    const auth = req.headers.get("Authorization")?.replace("Bearer ", "");
    if (!auth) return json({
      error: "No autorizado"
    }, 401);
    const sbAuth = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_ANON_KEY"), {
      global: {
        headers: {
          Authorization: `Bearer ${auth}`
        }
      }
    });
    const { data: user } = await sbAuth.auth.getUser();
    if (!user?.user) return json({
      error: "Token inválido"
    }, 401);
    const sbSR = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* ---------- Body ---------- */ const body = await req.json();
    const idCliente = Number(body.id_cliente);
    const idEstacion = body.id_estacion ? Number(body.id_estacion) : null;
    const idVehiculo = body.id_vehiculo ? Number(body.id_vehiculo) : null;
    const idConductor = body.id_conductor ? Number(body.id_conductor) : null;
    const fechaInicio = body.fecha_inicio; // yyyy-MM-dd
    const fechaFin = body.fecha_fin; // yyyy-MM-dd (YA SUMADA +1)
    if (!idCliente || isNaN(idCliente)) return json({
      error: "id_cliente es obligatorio"
    }, 400);
    let fechaDesde = null;
    let fechaHasta = null;
    if (fechaInicio && fechaFin) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(fechaInicio) || !/^\d{4}-\d{2}-\d{2}$/.test(fechaFin)) {
        return json({
          error: "Las fechas deben ser yyyy-MM-dd"
        }, 400);
      }
      // 🔥 RANGO PROFESIONAL
      fechaDesde = `${fechaInicio} 00:00:00-05`;
      fechaHasta = `${fechaFin} 00:00:00-05`; // IMPORTANTE: < fecha_fin
    }
    /* ---------- Query ---------- */ let q = sbSR.from("vw_historial_abastecimientos").select(`
        fecha_hora,
        estacion,
        tipo_combustible,
        galones,
        precio_gal,
        monto,
        vehiculo,
        conductor
      `).eq("id_cliente", idCliente).order("fecha_hora", {
      ascending: false
    });
    if (idEstacion) q = q.eq("id_estacion", idEstacion);
    if (idVehiculo) q = q.eq("id_vehiculo", idVehiculo);
    if (idConductor) q = q.eq("id_conductor", idConductor);
    if (fechaDesde && fechaHasta) {
      q = q.gte("fecha_hora", fechaDesde).lt("fecha_hora", fechaHasta); // 🔥 CLAVE
    }
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
      "Estación",
      "Tipo de combustible",
      "Galones",
      "Precio/Gal",
      "Consumo",
      "Vehículo",
      "Conductor"
    ];
    ws.addRow(headers);
    ws.getRow(1).font = {
      bold: true
    };
    ws.getRow(1).eachCell((c)=>c.border = thinBorder());
    data.forEach((r)=>{
      const row = ws.addRow([
        toLimaDateForExcel(r.fecha_hora),
        r.estacion,
        r.tipo_combustible,
        Number(r.galones),
        Number(r.precio_gal),
        Number(r.monto),
        r.vehiculo,
        r.conductor
      ]);
      row.eachCell((c)=>c.border = thinBorder());
    });
    ws.getColumn(1).numFmt = "dd/MM/yyyy HH:mm:ss";
    ws.getColumn(4).numFmt = "#,##0.00";
    ws.getColumn(5).numFmt = '"S/ " #,##0.00';
    autoFitColumns(ws, headers.length);
    const fileName = `Historial_Abastecimientos_${nowLimaCompact()}.xlsx`;
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
