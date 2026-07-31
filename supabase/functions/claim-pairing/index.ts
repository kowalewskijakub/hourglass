// claim-pairing — exchanges a one-time pairing code for a one-time login link.
//
// Why this exists: pairing must give the joining device a session OF ITS OWN.
// v1 handed over the first device's refresh token; refresh tokens rotate on
// use, so both devices ended up in one token family and GoTrue's reuse
// detection signed them both out within the hour. Here the service role mints
// a fresh magic-link token hash for the account instead — an independent
// session, an independent refresh-token family, nothing shared.
//
// Flow:
//   1. claim_pairing_code(code) atomically consumes the code -> account id
//      (single-use, 5-minute expiry, stored hashed; service-role-only RPC).
//   2. The account is anonymous, so it has no email for generateLink — give
//      it a synthetic, undeliverable one (RFC 2606 `.invalid`) once.
//   3. admin.generateLink(magiclink) returns a hashed token; the device
//      verifies it with auth.verifyOTP(tokenHash:type:.magiclink) and is in.
//
// Deploy:  supabase functions deploy claim-pairing
// (supabase/config.toml sets verify_jwt = false for this function — REQUIRED:
// the joining device is signed out, and with new-format sb_publishable_* keys
// the Swift SDK sends no Authorization header at all. If deploying without
// the config file, pass --no-verify-jwt explicitly.)

import { createClient } from "npm:@supabase/supabase-js@2";

const CODE_ALPHABET = /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/;

function respond(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return respond({ error: "POST only" }, 405);
  }

  let code: string;
  try {
    const payload = await req.json();
    code = String(payload.code ?? "").toUpperCase().replace(/[^A-Z2-9]/g, "");
  } catch {
    return respond({ error: "Malformed request." }, 400);
  }
  if (!CODE_ALPHABET.test(code)) {
    // Same reply as an expired code: no oracle for enumeration.
    return respond({ error: "That code is wrong, already used, or expired." });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // 1. Consume the code (single-use: the RPC deletes it as it reads it).
  const { data: userId, error: claimError } = await admin.rpc(
    "claim_pairing_code",
    { p_code: code },
  );
  if (claimError) {
    console.error("claim_pairing_code failed:", claimError.message);
    return respond({ error: "Pairing is unavailable right now." }, 500);
  }
  if (!userId) {
    return respond({ error: "That code is wrong, already used, or expired." });
  }

  // 2. Anonymous accounts carry no email; generateLink needs one. The address
  //    is synthetic and undeliverable by construction — the link never
  //    travels by mail, only back over this response.
  const { data: userData, error: userError } = await admin.auth.admin
    .getUserById(userId);
  if (userError || !userData?.user) {
    console.error("getUserById failed:", userError?.message);
    return respond({ error: "Pairing is unavailable right now." }, 500);
  }

  let email = userData.user.email;
  if (!email) {
    email = `${userId}@paired.hourglass.invalid`;
    const { error: updateError } = await admin.auth.admin.updateUserById(
      userId,
      { email, email_confirm: true },
    );
    if (updateError) {
      console.error("updateUserById failed:", updateError.message);
      return respond({ error: "Pairing is unavailable right now." }, 500);
    }
  }

  // 3. Mint the one-time login link and hand back only its token hash.
  const { data: linkData, error: linkError } = await admin.auth.admin
    .generateLink({ type: "magiclink", email });
  const tokenHash = linkData?.properties?.hashed_token;
  if (linkError || !tokenHash) {
    console.error("generateLink failed:", linkError?.message);
    return respond({ error: "Pairing is unavailable right now." }, 500);
  }

  return respond({ token_hash: tokenHash });
});
