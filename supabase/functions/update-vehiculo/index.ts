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
    const { uid_usuario, id_vehiculo, placa, tipo, marca, modelo, anio, tipos_combustible } = await req.json();
    /* ================= VALIDAR OBLIGATORIOS ================= */ if (!uid_usuario || !id_vehiculo || !placa || !tipo || !marca || !modelo) {
      return new Response(JSON.stringify({
        error: "Campos obligatorios incompletos."
      }), {
        status: 400,
        headers
      });
    }
    /* ================= VALIDAR ARRAY COMBUSTIBLE ================= */ if (tipos_combustible !== undefined && (!Array.isArray(tipos_combustible) || tipos_combustible.length === 0)) {
      return new Response(JSON.stringify({
        error: "tipos_combustible debe ser un arreglo con al menos un valor."
      }), {
        status: 400,
        headers
      });
    }
    /* ================= NORMALIZAR ================= */ const placaFinal = placa.trim();
    const tipoFinal = tipo.trim();
    const marcaFinal = marca.trim();
    const modeloFinal = modelo.trim();
    const anioFinal = anio !== undefined && anio !== null && anio !== "" && anio !== "null" ? Number(anio) : null;
    /* ================= VALIDAR AÑO ================= */ if (anioFinal !== null) {
      const currentYear = new Date().getFullYear();
      if (!Number.isInteger(anioFinal) || anioFinal < 1900 || anioFinal > currentYear) {
        return new Response(JSON.stringify({
          error: "El año debe estar entre 1900 y el año actual."
        }), {
          status: 400,
          headers
        });
      }
    }
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* ================= OBTENER DATA BEFORE ================= */ const { data: vehiculoActual } = await supabase.from("ms_vehiculos").select("*").eq("id_vehiculo", id_vehiculo).maybeSingle();
    if (!vehiculoActual) {
      return new Response(JSON.stringify({
        error: "El vehículo no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* ================= VALIDAR PLACA ÚNICA ================= */ if (placaFinal !== vehiculoActual.placa) {
      const { data: placaExiste } = await supabase.from("ms_vehiculos").select("id_vehiculo").eq("placa", placaFinal).neq("id_vehiculo", id_vehiculo).maybeSingle();
      if (placaExiste) {
        return new Response(JSON.stringify({
          error: "La placa ya está registrada."
        }), {
          status: 409,
          headers
        });
      }
    }
    /* ================= UPDATE ms_vehiculos ================= */ const { error } = await supabase.from("ms_vehiculos").update({
      placa: placaFinal,
      tipo: tipoFinal,
      marca: marcaFinal,
      modelo: modeloFinal,
      anio: anioFinal
    }).eq("id_vehiculo", id_vehiculo);
    if (error) {
      return new Response(JSON.stringify({
        error: "No se pudo actualizar el vehículo."
      }), {
        status: 500,
        headers
      });
    }
    /* ================= UPDATE COMBUSTIBLES ================= */ if (Array.isArray(tipos_combustible)) {
      await supabase.from("rl_vehiculo_combustible").delete().eq("id_vehiculo", id_vehiculo);
      if (tipos_combustible.length > 0) {
        const rows = tipos_combustible.map((id_combustible)=>({
            id_vehiculo,
            id_combustible
          }));
        await supabase.from("rl_vehiculo_combustible").insert(rows);
      }
    }
    /* ================= AUDITORÍA ================= */ const dataAfter = {
      ...vehiculoActual,
      placa: placaFinal,
      tipo: tipoFinal,
      marca: marcaFinal,
      modelo: modeloFinal,
      anio: anioFinal,
      tipos_combustible
    };
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_vehiculos",
      accion: "UPDATE_VEHICULO",
      registro_id: String(id_vehiculo),
      data_before: vehiculoActual,
      data_after: dataAfter
    });
    return new Response(JSON.stringify({
      success: true,
      message: "Vehículo actualizado correctamente."
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
