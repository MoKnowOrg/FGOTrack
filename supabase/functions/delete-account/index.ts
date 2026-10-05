import { createClient } from "npm:@supabase/supabase-js@2.57.4";

// No caller-supplied user ID is accepted. The server secret never enters the app.
Deno.serve(async (request: Request) => {
  const reply = (status: number, body: object) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  if (request.method !== "POST") return reply(405, { error: "POST required" });
  const token = request.headers.get("Authorization")?.match(/^Bearer (.+)$/i)?.[1];
  if (!token) return reply(401, { error: "Sign in first" });
  try {
    if ((await request.json()).confirm !== true) return reply(400, { error: "Confirm account deletion" });
    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: { user }, error: authError } = await admin.auth.getUser(token);
    if (authError || !user) return reply(401, { error: "Sign in again" });
    const { data: rooms, error: prepareError } = await admin.rpc("prepare_account_deletion", { p_user: user.id });
    if (prepareError) return reply(409, { error: prepareError.message });
    // Delete the actual files through Storage, never by deleting SQL metadata.
    const bucket = admin.storage.from("receipts");
    for (const prefix of [`personal/${user.id}`, ...(rooms ?? []).map((id: string) => `rooms/${id}`)]) {
      while (true) {
        const { data: files, error: listError } = await bucket.list(prefix, { limit: 1000, sortBy: { column: "name", order: "asc" } });
        if (listError) throw listError;
        if (!files?.length) break;
        if (files.some(file => !file.id)) throw new Error("Unexpected receipt folder; contact support");
        const { error: removeError } = await bucket.remove(files.map(file => `${prefix}/${file.name}`));
        if (removeError) throw removeError;
      }
    }
    const { error: finalizeError } = await admin.rpc("finalize_account_deletion", { p_user: user.id });
    if (finalizeError) throw finalizeError;
    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) throw deleteError;
    return reply(200, { deleted: true });
  } catch {
    // A prepared account is blocked from data access, but may retry this endpoint.
    return reply(500, { error: "Deletion did not finish. Retry, or contact business@knoworganization.com." });
  }
});
