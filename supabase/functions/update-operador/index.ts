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
        error: "Método no permitido"
      }), {
        status: 405,
        headers
      });
    }
    // =========================
    // BODY
    // =========================
    const { uid_usuario, email_actual, email_nuevo = null, password_nuevo = null } = await req.json();
    if (!uid_usuario || !email_actual) {
      return new Response(JSON.stringify({
        error: "Faltan campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    if (!email_nuevo && !password_nuevo) {
      return new Response(JSON.stringify({
        error: "Nada para actualizar."
      }), {
        status: 400,
        headers
      });
    }
    const emailActualNorm = email_actual.toLowerCase().trim();
    const emailNuevoNorm = email_nuevo ? email_nuevo.toLowerCase().trim() : null;
    // =========================
    // SUPABASE
    // =========================
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // =========================
    // LISTAR USERS AUTH
    // =========================
    const { data: usersData, error: listError } = await supabase.auth.admin.listUsers({
      page: 1,
      perPage: 1000
    });
    if (listError) {
      return new Response(JSON.stringify({
        error: "No se pudo consultar usuarios.",
        detalle: listError.message
      }), {
        status: 500,
        headers
      });
    }
    const user = usersData.users.find((u)=>u.email?.toLowerCase().trim() === emailActualNorm);
    if (!user) {
      return new Response(JSON.stringify({
        error: "Usuario no encontrado."
      }), {
        status: 404,
        headers
      });
    }
    // =========================
    // VALIDAR EMAIL NUEVO (OPCIÓN B)
    // =========================
    if (emailNuevoNorm) {
      const existeOtro = usersData.users.some((u)=>u.email?.toLowerCase().trim() === emailNuevoNorm && u.id !== user.id);
      if (existeOtro) {
        return new Response(JSON.stringify({
          error: "El nuevo correo ya pertenece a otro usuario."
        }), {
          status: 409,
          headers
        });
      }
    }
    // =========================
    // ARMAR UPDATE PAYLOAD
    // =========================
    const updatePayload = {};
    if (password_nuevo) {
      updatePayload.password = password_nuevo;
    }
    if (emailNuevoNorm && emailNuevoNorm !== emailActualNorm) {
      updatePayload.email = emailNuevoNorm;
    }
    // Si no hay cambios reales
    if (Object.keys(updatePayload).length === 0) {
      return new Response(JSON.stringify({
        success: true,
        message: "Sin cambios necesarios."
      }), {
        status: 200,
        headers
      });
    }
    // =========================
    // UPDATE AUTH
    // =========================
    const { error: updateError } = await supabase.auth.admin.updateUserById(user.id, updatePayload);
    if (updateError) {
      return new Response(JSON.stringify({
        error: "No se pudo actualizar usuario.",
        detalle: updateError.message
      }), {
        status: 500,
        headers
      });
    }
    // =========================
    // SINCRONIZAR TABLA OPERADOR
    // =========================
    if (updatePayload.email) {
      await supabase.from("ms_operadores_estacion").update({
        correo: updatePayload.email
      }).eq("id_usuario", user.id);
    }
    // =========================
    // AUDITORÍA
    // =========================
    await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "auth.users / ms_operadores_estacion",
      accion: "UPDATE_OPERADOR_CREDENCIALES",
      registro_id: user.id,
      data_before: {
        email: emailActualNorm
      },
      data_after: {
        email: updatePayload.email ?? emailActualNorm,
        password_updated: !!password_nuevo
      }
    });
    // =========================
    // RESPUESTA
    // =========================
    return new Response(JSON.stringify({
      success: true,
      message: "Credenciales actualizadas correctamente."
    }), {
      status: 200,
      headers
    });
  } catch (error) {
    console.error("ERROR:", error);
    return new Response(JSON.stringify({
      error: "Error inesperado.",
      detalle: error?.message ?? String(error)
    }), {
      status: 500,
      headers
    });
  }
});
