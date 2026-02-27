/**
 * Edge Function: registrar-abastecimiento
 * ------------------------------------------------------------
 * Objetivo:
 *  - Recibir un payload JSON desde el frontend/estación.
 *  - Validar que el payload tenga los campos mínimos.
 *  - Llamar vía RPC a la función SQL: public.fn_registrar_abastecimiento(...)
 *  - Retornar la respuesta de la función SQL al cliente.
 *
 * NOTAS IMPORTANTES:
 * 1) La validación “de verdad” (negocio / seguridad / consistencia) vive en la BD.
 *    Aquí hacemos validación mínima para evitar requests mal formados.
 *
 * 2) Este endpoint soporta CORS y responde a OPTIONS (preflight).
 *
 * 3) Esta función requiere el header 'Authorization: Bearer <token>'.
 */ // Tipos del runtime de Supabase para autocompletado / DX en Deno.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
// Cliente JS oficial para hablar con Supabase (RPC, queries, auth, etc.).
import { createClient } from "npm:@supabase/supabase-js@2";
// ✅ AGREGADO: Resend para envío de correo
import { Resend } from "npm:resend@2.0.0";
/**
 * Headers CORS.
 */ const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json"
    }
  });
}
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders
    });
  }
  if (req.method !== "POST") {
    return jsonResponse({
      ok: false,
      codigo: "METHOD_NOT_ALLOWED",
      mensaje: "Usa POST."
    }, 405);
  }
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader) {
      return jsonResponse({
        ok: false,
        codigo: "AUTH_REQUIRED",
        mensaje: "Falta el header 'Authorization: Bearer <token>'."
      }, 401);
    }
    const { id_cliente, id_estacion, id_vehiculo, id_conductor, id_combustible, galones, kilometraje, qrgenerado, id_operador = null, id_estado = 2 } = await req.json();
    const missing = [
      [
        "id_cliente",
        id_cliente
      ],
      [
        "id_estacion",
        id_estacion
      ],
      [
        "id_vehiculo",
        id_vehiculo
      ],
      [
        "id_conductor",
        id_conductor
      ],
      [
        "id_combustible",
        id_combustible
      ],
      [
        "galones",
        galones
      ],
      [
        "kilometraje",
        kilometraje
      ],
      [
        "qrgenerado",
        qrgenerado
      ]
    ].filter(([, v])=>v === undefined || v === null || v === "" || Number.isNaN(v));
    if (missing.length) {
      return jsonResponse({
        ok: false,
        codigo: "MISSING_PARAMS",
        mensaje: `Faltan campos: ${missing.map(([k])=>k).join(", ")}`
      }, 400);
    }
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !supabaseAnonKey) {
      return jsonResponse({
        ok: false,
        codigo: "MISSING_ENV",
        mensaje: "Faltan SUPABASE_URL o SUPABASE_ANON_KEY en el entorno."
      }, 500);
    }
    const supabaseKeyToUse = supabaseServiceRoleKey ?? supabaseAnonKey;
    const supabase = createClient(supabaseUrl, supabaseKeyToUse, {
      global: {
        headers: authHeader ? {
          Authorization: authHeader
        } : {}
      }
    });
    console.log("[registrar-abastecimiento] auth present", {
      hasAuthorization: Boolean(authHeader),
      usingServiceRole: Boolean(supabaseServiceRoleKey)
    });
    const { data, error } = await supabase.rpc("fn_registrar_abastecimiento", {
      p_id_cliente: id_cliente,
      p_id_estacion: id_estacion,
      p_id_vehiculo: id_vehiculo,
      p_id_conductor: id_conductor,
      p_id_combustible: id_combustible,
      p_galones: galones,
      p_kilometraje: kilometraje,
      p_qrgenerado: qrgenerado,
      p_id_operador: id_operador,
      p_id_estado: id_estado
    });
    if (error) {
      console.error("[registrar-abastecimiento] RPC_ERROR", error);
      return jsonResponse({
        ok: false,
        codigo: "RPC_ERROR",
        mensaje: error.message
      }, 400);
    }
    const row = Array.isArray(data) ? data[0] : data;
    const respuesta = {
      ...row ?? {},
      galones_registrados: galones,
      nro_transaccion: row?.nro_transaccion ?? null,
      kilometraje_registrado: kilometraje
    };
    // ============================================================
    // 10.2) ENVÍO DE CORREO AL CONTACTO PRINCIPAL DEL CLIENTE
    // ============================================================
    if (row?.ok === true) {
      try {
        const resendApiKey = Deno.env.get("RESEND_API_KEY");
        const fromEmail = Deno.env.get("RESEND_FROM_EMAIL");
        if (resendApiKey && fromEmail) {
          const resend = new Resend(resendApiKey);
          // Obtener contacto principal del cliente
          const { data: contacto } = await supabase.from("ms_contactos_cliente").select("email, nombre").eq("id_cliente", id_cliente).eq("contactoPrincipal", true).single();
          if (contacto?.email) {
            await resend.emails.send({
              from: fromEmail,
              to: contacto.email,
              subject: `Voucher Abastecimiento N° ${row?.nro_transaccion ?? ""}`,
              html: `
<div style="background:#f4f6f9;padding:30px 0;font-family:Arial,Helvetica,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0">
    <tr>
      <td align="center">
        <table width="420" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e7eb;">
          
          <!-- HEADER -->
          <tr>
            <td style="background:#E6875E;padding:20px;text-align:center;color:#ffffff;">
              <h2 style="margin:0;font-size:20px;">Detalle de Abastecimiento</h2>
            </td>
          </tr>

          <!-- BODY -->
          <tr>
            <td style="padding:25px;">

              <p style="margin:0;color:#1E3A8A;font-weight:bold;font-size:14px;">
                Número de Voucher
              </p>

              <p style="margin:5px 0 20px 0;color:#1E3A8A;font-size:20px;font-weight:bold;">
                ${row?.nro_transaccion ?? "-"}
              </p>

              <hr style="border:none;border-top:1px solid #e5e7eb;margin:15px 0;" />

              <p style="margin:10px 0;font-size:14px;">
                <strong>Fecha y Hora:</strong><br/>
                ${new Date().toLocaleString("es-PE")}
              </p>

              <p style="margin:10px 0;font-size:14px;">
                <strong>Vehículo:</strong><br/>
                ${vehiculo?.placa ?? `ID ${id_vehiculo}`}
              </p>

              <p style="margin:10px 0;font-size:14px;">
                <strong>Tipo de Combustible:</strong><br/>
                ${combustible?.nombre ?? `ID ${id_combustible}`}
              </p>

              <!-- KILOMETRAJE -->
              <table width="100%" cellpadding="0" cellspacing="0" style="background:#EEF3F8;border-radius:10px;margin-top:20px;">
                <tr>
                  <td align="center" style="padding:15px;">
                    <p style="margin:0;font-size:13px;font-weight:bold;">Kilometraje</p>
                    <p style="margin:5px 0 0 0;font-size:20px;font-weight:bold;">
                      ${kilometraje} km
                    </p>
                  </td>
                </tr>
              </table>

              <!-- GALONES + TOTAL -->
              <table width="100%" cellpadding="0" cellspacing="0" style="background:#E6EFF7;border-radius:10px;margin-top:20px;">
                <tr>
                  <td style="padding:15px;">
                    <table width="100%">
                      <tr>
                        <td style="font-size:13px;font-weight:bold;">
                          Galones despachados
                          <p style="margin:5px 0 0 0;font-size:18px;font-weight:bold;">
                            ${galones}
                          </p>
                        </td>
                        <td align="right" style="font-size:13px;font-weight:bold;">
                          Total
                          <p style="margin:5px 0 0 0;font-size:18px;font-weight:bold;">
                            S/ ${row?.total ?? "-"}
                          </p>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
              </table>

              <p style="margin-top:25px;font-size:12px;color:#9ca3af;text-align:center;">
                Voucher generado automáticamente.
              </p>

            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</div>
`
            });
            console.log("[EMAIL] Enviado a contacto principal:", contacto.email);
          }
        }
      } catch (emailError) {
        console.error("[EMAIL_ERROR]", emailError);
      }
    }
    return jsonResponse(respuesta, 200);
  } catch (e) {
    console.error("[registrar-abastecimiento] UNHANDLED", e);
    return jsonResponse({
      ok: false,
      codigo: "UNHANDLED",
      mensaje: e?.message ?? String(e)
    }, 500);
  }
});
