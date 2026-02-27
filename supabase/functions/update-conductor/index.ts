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
    ===================================================== */ const { uid_usuario, id_conductor, nombre, dni, telefono, licencia, fecha_vencimiento_licencia, categoria, email, tipos_combustible, password// 👈 NUEVO (opcional)
     } = await req.json();
    if (!uid_usuario || !id_conductor || !nombre || !dni || !licencia || !email) {
      return new Response(JSON.stringify({
        error: "Campos obligatorios incompletos."
      }), {
        status: 400,
        headers
      });
    }
    // ✅ validar password solo si viene (mínimo 6)
    if (password !== undefined && password !== null && String(password).trim() !== "" && String(password).length < 6) {
      return new Response(JSON.stringify({
        error: "La contraseña debe tener al menos 6 caracteres."
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
    const emailNormalized = email.toLowerCase().trim();
    /* =====================================================
       2️⃣ NORMALIZAR OPCIONALES
    ===================================================== */ const telefonoFinal = telefono && telefono !== "" && telefono !== "null" ? telefono : null;
    const fechaLicenciaFinal = fecha_vencimiento_licencia && fecha_vencimiento_licencia !== "" && fecha_vencimiento_licencia !== "null" ? fecha_vencimiento_licencia : null;
    const categoriaFinal = categoria && categoria !== "" && categoria !== "null" ? categoria : null;
    /* =====================================================
       3️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       4️⃣ OBTENER CONDUCTOR ACTUAL (data_before)
    ===================================================== */ const { data: conductorActual } = await supabase.from("ms_conductores").select("*").eq("id_conductor", id_conductor).maybeSingle();
    if (!conductorActual) {
      return new Response(JSON.stringify({
        error: "El conductor no existe."
      }), {
        status: 404,
        headers
      });
    }
    const id_usuario = conductorActual.id_usuario;
    /* =====================================================
       5️⃣ VALIDACIONES
    ===================================================== */ if (dni !== conductorActual.dni) {
      const { data: dniExiste } = await supabase.from("ms_conductores").select("id_conductor").eq("dni", dni).neq("id_conductor", id_conductor).maybeSingle();
      if (dniExiste) {
        return new Response(JSON.stringify({
          error: "El DNI ya está registrado."
        }), {
          status: 409,
          headers
        });
      }
    }
    if (licencia !== conductorActual.licencia) {
      const { data: licenciaExiste } = await supabase.from("ms_conductores").select("id_conductor").eq("licencia", licencia).neq("id_conductor", id_conductor).maybeSingle();
      if (licenciaExiste) {
        return new Response(JSON.stringify({
          error: "La licencia ya está registrada."
        }), {
          status: 409,
          headers
        });
      }
    }
    /* =====================================================
       6️⃣ ACTUALIZAR AUTH (email)
    ===================================================== */ await supabase.auth.admin.updateUserById(id_usuario, {
      email: emailNormalized
    });
    /* =====================================================
       ✅ 6.1️⃣ ACTUALIZAR AUTH (password si viene)
    ===================================================== */ let password_updated = false;
    if (password !== undefined && password !== null && String(password).trim() !== "") {
      const { error: passErr } = await supabase.auth.admin.updateUserById(id_usuario, {
        password: String(password)
      });
      if (passErr) {
        return new Response(JSON.stringify({
          error: "No se pudo actualizar la contraseña del conductor."
        }), {
          status: 500,
          headers
        });
      }
      password_updated = true;
    }
    /* =====================================================
       7️⃣ UPDATE ms_conductores
    ===================================================== */ await supabase.from("ms_conductores").update({
      nombre,
      dni,
      telefono: telefonoFinal,
      licencia,
      fecha_vencimiento_licencia: fechaLicenciaFinal,
      categoria: categoriaFinal,
      email: emailNormalized
    }).eq("id_conductor", id_conductor);
    /* =====================================================
       8️⃣ UPDATE COMBUSTIBLES
    ===================================================== */ if (Array.isArray(tipos_combustible)) {
      await supabase.from("rl_conductor_combustible").delete().eq("id_conductor", id_conductor);
      if (tipos_combustible.length > 0) {
        const rows = tipos_combustible.map((id_combustible)=>({
            id_conductor,
            id_combustible
          }));
        await supabase.from("rl_conductor_combustible").insert(rows);
      }
    }
    /* =====================================================
       9️⃣ AUDITORÍA
    ===================================================== */ const dataAfter = {
      ...conductorActual,
      nombre,
      dni,
      telefono: telefonoFinal,
      licencia,
      fecha_vencimiento_licencia: fechaLicenciaFinal,
      categoria: categoriaFinal,
      email: emailNormalized,
      tipos_combustible,
      password_updated
    };
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_conductores",
      accion: "UPDATE_CONDUCTOR",
      registro_id: String(id_conductor),
      data_before: conductorActual,
      data_after: dataAfter
    });
    /* =====================================================
       🔟 RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Conductor actualizado correctamente.",
      fecha_vencimiento_licencia: fechaLicenciaFinal ? `${fechaLicenciaFinal}T00:00:00` : null
    }), {
      status: 200,
      headers
    });
  } catch (error) {
    return new Response(JSON.stringify({
      error: "Error inesperado.",
      detalle: error?.message ?? error
    }), {
      status: 500,
      headers
    });
  }
});
