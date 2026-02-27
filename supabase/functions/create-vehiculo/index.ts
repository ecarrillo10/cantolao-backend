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
    const { uid_usuario, id_cliente, placa, tipo, marca, modelo, anio, id_centro_costo, tipos_combustible } = await req.json();
    /* ================= VALIDAR OBLIGATORIOS ================= */ if (!uid_usuario || !id_cliente || !placa || !tipo || !marca || !modelo) {
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
    /* ================= CENTRO DE COSTO (OPCIONAL) ================= */ const idCentroCostoFinal = id_centro_costo !== undefined && id_centro_costo !== null && id_centro_costo !== "" && id_centro_costo !== "null" ? Number(id_centro_costo) : null;
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* ================= VALIDAR PLACA ÚNICA ================= */ const { data: placaExiste } = await supabase.from("ms_vehiculos").select("id_vehiculo").eq("placa", placaFinal).maybeSingle();
    if (placaExiste) {
      return new Response(JSON.stringify({
        error: "La placa ya está registrada."
      }), {
        status: 409,
        headers
      });
    }
    /* ================= INSERT VEHÍCULO ================= */ const { data, error } = await supabase.from("ms_vehiculos").insert({
      id_cliente,
      placa: placaFinal,
      tipo: tipoFinal,
      marca: marcaFinal,
      modelo: modeloFinal,
      anio: anioFinal,
      id_centro_costo: idCentroCostoFinal,
      estado: true
    }).select().maybeSingle();
    if (error || !data) {
      return new Response(JSON.stringify({
        error: "No se pudo crear el vehículo."
      }), {
        status: 500,
        headers
      });
    }
    /* ================= INSERT RELACIÓN COMBUSTIBLES ================= */ if (Array.isArray(tipos_combustible) && tipos_combustible.length > 0) {
      const relaciones = tipos_combustible.map((id_combustible)=>({
          id_vehiculo: data.id_vehiculo,
          id_combustible
        }));
      const { error: errorComb } = await supabase.from("rl_vehiculo_combustible").insert(relaciones);
      if (errorComb) {
        return new Response(JSON.stringify({
          error: "Vehículo creado, pero falló la asignación de combustibles."
        }), {
          status: 500,
          headers
        });
      }
    }
    /* ================= AUDITORÍA ================= */ const dataAfter = {
      ...data,
      tipos_combustible: tipos_combustible ?? []
    };
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_vehiculos",
      accion: "INSERT_VEHICULO",
      registro_id: String(data.id_vehiculo),
      data_before: null,
      data_after: dataAfter
    });
    return new Response(JSON.stringify({
      success: true,
      message: "Vehículo creado correctamente.",
      vehiculo: data
    }), {
      status: 201,
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
