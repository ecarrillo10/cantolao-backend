import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type"
  };
  // =========================
  // CORS PREFLIGHT
  // =========================
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
    const { uid_usuario, email, password, id_estacion, activo = true } = await req.json();
    if (!uid_usuario || !email || !password || !id_estacion) {
      return new Response(JSON.stringify({
        error: "Faltan campos obligatorios."
      }), {
        status: 400,
        headers
      });
    }
    const emailNormalized = String(email).toLowerCase().trim();
    // =========================
    // SUPABASE SERVICE ROLE
    // =========================
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // =========================
    // VALIDAR EMAIL EN AUTH
    // =========================
    const { data: usersData, error: listError } = await supabase.auth.admin.listUsers({
      page: 1,
      perPage: 1000
    });
    if (listError) {
      return new Response(JSON.stringify({
        error: "No se pudo validar el correo.",
        detalle: listError.message
      }), {
        status: 500,
        headers
      });
    }
    const existe = usersData.users.some((u)=>u.email?.toLowerCase().trim() === emailNormalized);
    if (existe) {
      return new Response(JSON.stringify({
        error: "El correo ya existe."
      }), {
        status: 409,
        headers
      });
    }
    // =========================
    // CREAR AUTH USER
    // =========================
    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email: emailNormalized,
      password,
      email_confirm: true
    });
    if (authError || !authData?.user) {
      return new Response(JSON.stringify({
        error: "No se pudo crear el usuario.",
        detalle: authError?.message ?? "authData.user null"
      }), {
        status: 500,
        headers
      });
    }
    const idUsuario = authData.user.id;
    // =========================
    // INSERTAR OPERADOR ESTACION
    // =========================
    const operador = {
      id_usuario: idUsuario,
      id_estacion,
      activo,
      correo: emailNormalized
    };
    const { data: opInsert, error: opError } = await supabase.from("ms_operadores_estacion").insert(operador).select("id_operador").single();
    if (opError) {
      // rollback auth
      await supabase.auth.admin.deleteUser(idUsuario);
      return new Response(JSON.stringify({
        error: "Error al crear operador estación.",
        detalle: opError.message
      }), {
        status: 500,
        headers
      });
    }
    // =========================
    // AUDITORÍA
    // =========================
    const { error: auditError } = await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_operadores_estacion",
      accion: "CREATE_OPERADOR_ESTACION",
      registro_id: String(opInsert.id_operador),
      data_before: null,
      data_after: operador
    });
    if (auditError) {
      console.error("AUDITORIA ERROR:", auditError.message);
    // no rompemos flujo — operador ya fue creado
    }
    // =========================
    // RESPUESTA OK
    // =========================
    return new Response(JSON.stringify({
      success: true,
      message: "Operador estación creado correctamente.",
      id_operador: opInsert.id_operador,
      id_usuario: idUsuario
    }), {
      status: 201,
      headers
    });
  } catch (error) {
    console.error("CATCH ERROR:", error);
    return new Response(JSON.stringify({
      error: "Error inesperado.",
      detalle: error?.message ?? String(error)
    }), {
      status: 500,
      headers
    });
  }
});
