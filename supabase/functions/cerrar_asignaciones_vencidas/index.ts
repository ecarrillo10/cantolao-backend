import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async ()=>{
  try {
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // Fecha actual en formato YYYY-MM-DD (DATE)
    const hoy = new Date().toISOString().substring(0, 10);
    // Cerrar asignaciones vencidas
    const { data, error } = await supabase.from("cb_asignaciones_conductor").update({
      estado: false
    }).eq("estado", true).not("fecha_fin", "is", null).lt("fecha_fin", hoy).select("id_asignacion");
    if (error) {
      return new Response(JSON.stringify({
        success: false,
        error: error.message
      }), {
        status: 500
      });
    }
    return new Response(JSON.stringify({
      success: true,
      message: "Asignaciones vencidas cerradas correctamente.",
      total_cerradas: data?.length ?? 0,
      fecha_ejecucion: hoy
    }), {
      status: 200
    });
  } catch (err) {
    return new Response(JSON.stringify({
      success: false,
      error: "Error inesperado",
      detalle: err?.message ?? err
    }), {
      status: 500
    });
  }
});
