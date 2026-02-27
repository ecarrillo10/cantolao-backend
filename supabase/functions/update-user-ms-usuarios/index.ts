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
        error: "Método no permitido."
      }), {
        status: 405,
        headers
      });
    }
    /* =====================================================
       1️⃣ BODY
    ===================================================== */ const { id_usuario, email, nombre, apellido, dni } = await req.json();
    if (!id_usuario || !email || !nombre || !dni) {
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
       3️⃣ VALIDAR USUARIO EN ms_usuarios
    ===================================================== */ const { data: usuarioActual } = await supabase.from("ms_usuarios").select("id_usuario, email, dni").eq("id_usuario", id_usuario).maybeSingle();
    if (!usuarioActual) {
      return new Response(JSON.stringify({
        error: "El usuario que intentas editar no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       4️⃣ VALIDAR EXISTENCIA EN AUTH
    ===================================================== */ const { data: authUser, error: authGetError } = await supabase.auth.admin.getUserById(id_usuario);
    if (authGetError || !authUser?.user) {
      return new Response(JSON.stringify({
        error: "El usuario no existe en el sistema de autenticación (Auth)."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       5️⃣ VALIDAR EMAIL SOLO EN AUTH (SI CAMBIÓ)
    ===================================================== */ if (emailNormalized !== usuarioActual.email) {
      const { data: authUsers, error: authListError } = await supabase.auth.admin.listUsers({
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
      if (authUsers?.users.some((u)=>u.email?.toLowerCase().trim() === emailNormalized && u.id !== id_usuario)) {
        return new Response(JSON.stringify({
          error: "El correo electrónico ya se encuentra registrado."
        }), {
          status: 409,
          headers
        });
      }
    }
    /* =====================================================
       6️⃣ VALIDAR DNI SOLO EN ms_usuarios (SI CAMBIÓ)
    ===================================================== */ if (dni !== usuarioActual.dni) {
      const { data: dniExiste } = await supabase.from("ms_usuarios").select("id_usuario").eq("dni", dni).neq("id_usuario", id_usuario).maybeSingle();
      if (dniExiste) {
        return new Response(JSON.stringify({
          error: "Este DNI ya se encuentra registrado."
        }), {
          status: 409,
          headers
        });
      }
    }
    /* =====================================================
       7️⃣ ACTUALIZAR EMAIL EN AUTH (SI CAMBIÓ)
    ===================================================== */ if (emailNormalized !== usuarioActual.email) {
      const { error: authUpdateError } = await supabase.auth.admin.updateUserById(id_usuario, {
        email: emailNormalized
      });
      if (authUpdateError) {
        return new Response(JSON.stringify({
          error: "No se pudo actualizar el correo en Auth."
        }), {
          status: 500,
          headers
        });
      }
    }
    /* =====================================================
       8️⃣ ACTUALIZAR ms_usuarios
    ===================================================== */ const { error: updateError } = await supabase.from("ms_usuarios").update({
      nombre,
      apellido,
      email: emailNormalized,
      dni
    }).eq("id_usuario", id_usuario);
    if (updateError) {
      return new Response(JSON.stringify({
        error: "Ocurrió un error al actualizar la información."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       9️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "La información del usuario se actualizó correctamente."
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error("EDGE ERROR:", error);
    return new Response(JSON.stringify({
      error: "Ocurrió un error inesperado. Inténtalo más tarde."
    }), {
      status: 500,
      headers
    });
  }
});
