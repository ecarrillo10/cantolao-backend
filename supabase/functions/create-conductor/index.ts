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
    ===================================================== */ const { uid_usuario, id_cliente, nombre, dni, telefono, licencia, fecha_vencimiento_licencia, categoria, email, password } = await req.json();
    if (!uid_usuario || !nombre || !dni || !licencia || !email || !password) {
      return new Response(JSON.stringify({
        error: "Campos obligatorios incompletos."
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
    const idClienteFinal = id_cliente && id_cliente !== "" && id_cliente !== "null" ? id_cliente : null;
    /* =====================================================
       3️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       4️⃣ VALIDACIONES
    ===================================================== */ const { data: dniExiste } = await supabase.from("ms_conductores").select("id_usuario").eq("dni", dni).maybeSingle();
    if (dniExiste) {
      return new Response(JSON.stringify({
        error: "El DNI ya está registrado."
      }), {
        status: 409,
        headers
      });
    }
    const { data: licenciaExiste } = await supabase.from("ms_conductores").select("id_usuario").eq("licencia", licencia).maybeSingle();
    if (licenciaExiste) {
      return new Response(JSON.stringify({
        error: "La licencia ya está registrada."
      }), {
        status: 409,
        headers
      });
    }
    const { data: emailExisteBD } = await supabase.from("ms_conductores").select("id_usuario").eq("email", emailNormalized).maybeSingle();
    if (emailExisteBD) {
      return new Response(JSON.stringify({
        error: "El correo ya está registrado"
      }), {
        status: 409,
        headers
      });
    }
    const { data: authUsers } = await supabase.auth.admin.listUsers({
      page: 1,
      perPage: 1000
    });
    if (authUsers?.users.some((u)=>u.email?.toLowerCase() === emailNormalized)) {
      return new Response(JSON.stringify({
        error: "El correo ya está registrado."
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       5️⃣ CREAR USUARIO AUTH
    ===================================================== */ const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email: emailNormalized,
      password,
      email_confirm: true
    });
    if (authError || !authData?.user) {
      return new Response(JSON.stringify({
        error: "No se pudo crear el usuario."
      }), {
        status: 500,
        headers
      });
    }
    const id_usuario = authData.user.id;
    /* =====================================================
       6️⃣ INSERTAR ms_conductores
    ===================================================== */ const { data: conductorInsertado, error: insertError } = await supabase.from("ms_conductores").insert({
      id_usuario,
      id_cliente: idClienteFinal,
      nombre,
      dni,
      telefono: telefonoFinal,
      licencia,
      fecha_vencimiento_licencia: fechaLicenciaFinal,
      categoria: categoriaFinal,
      email: emailNormalized,
      estado: true
    }).select().single();
    if (insertError || !conductorInsertado) {
      await supabase.auth.admin.deleteUser(id_usuario);
      return new Response(JSON.stringify({
        error: "No se pudo registrar el conductor.",
        detalle: insertError?.message
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       7️⃣ AUDITORÍA
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_conductores",
      accion: "INSERT_CONDUCTOR",
      registro_id: String(conductorInsertado.id_usuario),
      data_before: null,
      data_after: conductorInsertado
    });
    /* =====================================================
       8️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Conductor creado correctamente.",
      fecha_vencimiento_licencia: fechaLicenciaFinal ? `${fechaLicenciaFinal}T00:00:00` : null
    }), {
      status: 201,
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
