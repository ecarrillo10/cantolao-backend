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
    ===================================================== */ const { uid_usuario, id_contacto, email, nombre, telefono, password } = await req.json();
    if (!uid_usuario || !id_contacto || !email || !nombre) {
      return new Response(JSON.stringify({
        error: "Completa todos los campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    // password opcional: si viene, validar mínimo
    if (password !== undefined && password !== null && String(password).trim() !== "" && String(password).length < 6) {
      return new Response(JSON.stringify({
        error: "La contraseña debe tener al menos 6 caracteres."
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
       3️⃣ VALIDAR CONTACTO EXISTE
    ===================================================== */ const { data: contactoActual } = await supabase.from("ms_contactos_cliente").select("*").eq("id_contacto", id_contacto).maybeSingle();
    if (!contactoActual) {
      return new Response(JSON.stringify({
        error: "El contacto que intentas editar no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       4️⃣ VALIDAR EMAIL EN AUTH (SI CAMBIÓ)
    ===================================================== */ if ((emailNormalized ?? "") !== (contactoActual.email ?? "")) {
      const { data: authUsers } = await supabase.auth.admin.listUsers({
        page: 1,
        perPage: 1000
      });
      if (authUsers?.users.some((u)=>u.email?.toLowerCase() === emailNormalized && u.id !== id_contacto)) {
        return new Response(JSON.stringify({
          error: "Este correo ya está registrado en el sistema."
        }), {
          status: 409,
          headers
        });
      }
      /* =====================================================
         5️⃣ ACTUALIZAR EMAIL EN AUTH
      ===================================================== */ const { error: authUpdateError } = await supabase.auth.admin.updateUserById(id_contacto, {
        email: emailNormalized
      });
      if (authUpdateError) {
        return new Response(JSON.stringify({
          error: "No se pudo actualizar el correo del contacto."
        }), {
          status: 500,
          headers
        });
      }
    }
    /* =====================================================
       ✅ 5.1️⃣ ACTUALIZAR PASSWORD EN AUTH (SI VIENE)
    ===================================================== */ let passwordUpdated = false;
    if (password !== undefined && password !== null && String(password).trim() !== "") {
      const { error: passUpdateError } = await supabase.auth.admin.updateUserById(id_contacto, {
        password: String(password)
      });
      if (passUpdateError) {
        return new Response(JSON.stringify({
          error: "No se pudo actualizar la contraseña del contacto."
        }), {
          status: 500,
          headers
        });
      }
      passwordUpdated = true;
    }
    /* =====================================================
       6️⃣ ACTUALIZAR ms_contactos_cliente
    ===================================================== */ const { error: updateError } = await supabase.from("ms_contactos_cliente").update({
      nombre,
      email: emailNormalized,
      telefono
    }).eq("id_contacto", id_contacto);
    if (updateError) {
      return new Response(JSON.stringify({
        error: "Ocurrió un error al actualizar el contacto."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       ✅ AUDITORÍA (SIN ROMPER TU LÓGICA)
    ===================================================== */ const dataAfter = {
      ...contactoActual,
      nombre,
      email: emailNormalized,
      telefono,
      password_updated: passwordUpdated
    };
    const { error: auditError } = await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_contactos_cliente",
      accion: "UPDATE_CONTACTO_CLIENTE",
      registro_id: String(id_contacto),
      data_before: contactoActual,
      data_after: dataAfter
    });
    if (auditError) {
      console.error("AUDITORIA ERROR:", auditError);
    }
    /* =====================================================
       7️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "La información del contacto se actualizó correctamente.",
      password_updated: passwordUpdated
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
