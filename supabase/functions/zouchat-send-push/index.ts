import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const PROJECT_ID = "zouchat-a0f5a";
const ALLOWED_ORIGIN = "https://zoumanasanogo224-tech.github.io";
const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function encodeJson(value: unknown): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

async function getGoogleAccessToken(account: { client_email: string; private_key: string }) {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = encodeJson({ alg: "RS256", typ: "JWT" }) + "." +
    encodeJson({
      iss: account.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: now,
      exp: now + 3600,
    });
  const pem = account.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const keyBytes = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", keyBytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned),
  ));
  const assertion = unsigned + "." + base64Url(signature);
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  const result = await response.json();
  if (!response.ok || !result.access_token) {
    throw new Error("Google OAuth token request failed: " + (result.error_description || result.error || response.status));
  }
  return result.access_token as string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const origin = req.headers.get("origin");
  if (origin && origin !== ALLOWED_ORIGIN) return json({ error: "Origin not allowed" }, 403);

  const authorization = req.headers.get("authorization") || "";
  const accessToken = authorization.replace(/^Bearer\s+/i, "");
  if (!accessToken) return json({ error: "Authentication required" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: "Supabase server configuration is incomplete" }, 500);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser(accessToken);
  if (userError || !userData.user) return json({ error: "Invalid session" }, 401);
  const userId = userData.user.id;

  let body: { message_id?: string; conversation_id?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  if (!body.message_id || !body.conversation_id) {
    return json({ error: "message_id and conversation_id are required" }, 400);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: message, error: messageError } = await admin
    .from("messages")
    .select("id, conversation_id, sender_id")
    .eq("id", body.message_id)
    .eq("conversation_id", body.conversation_id)
    .maybeSingle();
  if (messageError || !message || message.sender_id !== userId) {
    return json({ error: "Message not found or not owned by caller" }, 404);
  }

  const { data: senderMembership } = await admin
    .from("conversation_members")
    .select("user_id")
    .eq("conversation_id", body.conversation_id)
    .eq("user_id", userId)
    .maybeSingle();
  if (!senderMembership) return json({ error: "Not a conversation member" }, 403);

  const { data: recipients, error: membersError } = await admin
    .from("conversation_members")
    .select("user_id")
    .eq("conversation_id", body.conversation_id)
    .neq("user_id", userId);
  if (membersError) return json({ error: "Could not load conversation recipients" }, 500);
  const recipientIds = (recipients || []).map((row) => row.user_id);
  if (!recipientIds.length) return json({ sent: 0, reason: "No recipients" });

  const { data: tokenRows, error: tokenError } = await admin
    .from("zouchat_push_tokens")
    .select("fcm_token")
    .in("user_id", recipientIds);
  if (tokenError) return json({ error: "Could not load notification tokens" }, 500);
  const tokens = [...new Set((tokenRows || []).map((row) => row.fcm_token).filter(Boolean))];
  if (!tokens.length) return json({ sent: 0, reason: "Recipients have not enabled Android notifications" });

  const serviceAccountRaw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
  if (!serviceAccountRaw) {
    return json({ error: "Firebase service account secret is not configured yet" }, 503);
  }

  let serviceAccount: { project_id: string; client_email: string; private_key: string };
  try { serviceAccount = JSON.parse(serviceAccountRaw); } catch {
    return json({ error: "FIREBASE_SERVICE_ACCOUNT must contain valid service-account JSON" }, 500);
  }
  if (serviceAccount.project_id !== PROJECT_ID || !serviceAccount.client_email || !serviceAccount.private_key) {
    return json({ error: "Firebase service account does not match the ZouChat Firebase project" }, 500);
  }

  try {
    const googleToken = await getGoogleAccessToken(serviceAccount);
    const results = await Promise.all(tokens.map(async (token) => {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${PROJECT_ID}/messages:send`,
        {
          method: "POST",
          headers: {
            "Authorization": "Bearer " + googleToken,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              token,
              notification: {
                title: "Nouveau message ZouChat",
                body: "Tu as reçu un nouveau message.",
              },
              data: { conversation_id: body.conversation_id },
              android: { priority: "HIGH", notification: { channel_id: "zouchat_messages" } },
            },
          }),
        },
      );
      if (response.ok) return true;
      const detail = await response.text();
      console.error("FCM send failed", response.status, detail.slice(0, 500));
      return false;
    }));
    return json({ sent: results.filter(Boolean).length, failed: results.filter((x) => !x).length });
  } catch (error) {
    console.error("Push notification error", error);
    return json({ error: "Notification service failed" }, 502);
  }
});
