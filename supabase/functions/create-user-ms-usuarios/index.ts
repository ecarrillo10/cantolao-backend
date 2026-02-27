import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  // =====================================================
  // CORS (PATRÓN ESTABLE – PROYECTO ANTERIOR)
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
       1️⃣ BODY
    ===================================================== */ const { uid_usuario, email, password, nombre, apellido, dni, estado = true } = await req.json();
    if (!uid_usuario || !email || !password || !nombre || !dni) {
      return new Response(JSON.stringify({
        error: "Completa todos los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    const emailNormalized = email.toLowerCase().trim();
    /* =====================================================
       2️⃣ SERVICE ROLE
    ===================================================== */ const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    /* =====================================================
       3️⃣ VALIDAR CORREO SOLO EN AUTH
    ===================================================== */ const { data: authUsers, error: authListError } = await supabase.auth.admin.listUsers({
      page: 1,
      perPage: 1000
    });
    if (authListError) {
      return new Response(JSON.stringify({
        error: "No se pudo validar el correo electrónico."
      }), {
        status: 500,
        headers
      });
    }
    if (authUsers?.users.some((u)=>u.email?.toLowerCase().trim() === emailNormalized)) {
      return new Response(JSON.stringify({
        error: "El correo electrónico ya se encuentra registrado."
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       4️⃣ VALIDAR SOLO DNI EN ms_usuarios
    ===================================================== */ const { data: dniExiste } = await supabase.from("ms_usuarios").select("id_usuario").eq("dni", dni).maybeSingle();
    if (dniExiste) {
      return new Response(JSON.stringify({
        error: "Este DNI ya se encuentra registrado."
      }), {
        status: 409,
        headers
      });
    }
    /* =====================================================
       5️⃣ CREAR USUARIO EN AUTH
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
    const nuevoUsuario = {
      id_usuario: authData.user.id,
      nombre,
      apellido,
      email: emailNormalized,
      dni,
      estado
    };
    /* =====================================================
       6️⃣ INSERTAR EN ms_usuarios
    ===================================================== */ const { error: insertError } = await supabase.from("ms_usuarios").insert(nuevoUsuario);
    if (insertError) {
      return new Response(JSON.stringify({
        error: "El usuario fue creado, pero ocurrió un error al guardar su información."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       📘 AUDITORÍA
    ===================================================== */ await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_usuarios",
      accion: "CREATE_USUARIO",
      registro_id: authData.user.id,
      data_before: null,
      data_after: nuevoUsuario
    });
    /* =====================================================
       7️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Usuario creado correctamente."
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "Ocurrió un error inesperado."
    }), {
      status: 500,
      headers
    });
  }
});
