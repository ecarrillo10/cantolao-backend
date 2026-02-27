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
    ===================================================== */ const { uid_usuario, id_cliente, email, password, nombre, telefono } = await req.json();
    if (!uid_usuario || !id_cliente || !email || !password || !nombre) {
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
       3️⃣ VALIDAR CLIENTE
    ===================================================== */ const { data: cliente } = await supabase.from("ms_clientes").select("id_cliente").eq("id_cliente", id_cliente).maybeSingle();
    if (!cliente) {
      return new Response(JSON.stringify({
        error: "El cliente seleccionado no existe."
      }), {
        status: 404,
        headers
      });
    }
    /* =====================================================
       ✅ (NUEVO) DEFINIR SI SERÁ CONTACTO PRINCIPAL
       - Si NO tiene contactos activos -> true (primer contacto)
       - Si ya tiene 1 o más -> false
       (no cambia tu lógica; solo setea el boolean)
    ===================================================== */ const { count: contactosActivosCount } = await supabase.from("ms_contactos_cliente").select("id_contacto", {
      count: "exact",
      head: true
    }).eq("id_cliente", id_cliente).eq("estado", true);
    const esPrincipal = (contactosActivosCount ?? 0) === 0;
    /* =====================================================
       4️⃣ VALIDAR EMAIL ÚNICO EN AUTH
    ===================================================== */ const { data: authUsers } = await supabase.auth.admin.listUsers({
      page: 1,
      perPage: 1000
    });
    if (authUsers?.users.some((u)=>u.email?.toLowerCase() === emailNormalized)) {
      return new Response(JSON.stringify({
        error: "Este correo ya está registrado en el sistema."
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
        error: "No se pudo crear el usuario del contacto."
      }), {
        status: 500,
        headers
      });
    }
    const id_contacto = authData.user.id;
    /* =====================================================
       6️⃣ INSERTAR CONTACTO CLIENTE
    ===================================================== */ const contactoData = {
      id_contacto,
      id_cliente,
      nombre,
      email: emailNormalized,
      telefono,
      contactoPrincipal: esPrincipal,
      estado: true
    };
    const { error: insertError } = await supabase.from("ms_contactos_cliente").insert(contactoData);
    if (insertError) {
      return new Response(JSON.stringify({
        error: "No se pudo registrar el contacto del cliente."
      }), {
        status: 500,
        headers
      });
    }
    /* =====================================================
       ✅ AUDITORÍA
    ===================================================== */ const { error: auditError } = await supabase.from("auditoria").insert({
      usuario: uid_usuario,
      tabla_afectada: "ms_contactos_cliente",
      accion: "INSERT_CONTACTO_CLIENTE",
      registro_id: id_contacto,
      data_before: null,
      data_after: contactoData
    });
    if (auditError) {
      console.error("AUDITORIA ERROR:", auditError);
    }
    /* =====================================================
       7️⃣ RESPUESTA FINAL
    ===================================================== */ return new Response(JSON.stringify({
      success: true,
      message: "Contacto del cliente registrado correctamente."
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
