// deno-lint-ignore-file no-explicit-any
// =====================================================================
// admin-users  -  Supabase Edge Function  (DDD Hostel, Phase 5, needs SQL 027)
//
// Director-only management of MANAGER logins (database role "head_manager",
// the new Director-level role from 027_roles_permissions.sql; NOT the hostel
// warden, whose role is "manager"). Owner rule R1: only the real Director adds,
// edits, deactivates, removes Managers and resets their password. A Manager can
// never touch the Director (027 also blocks that inside the database).
//
//   POST { action: "create_manager",  full_name, mobile, login_id, password }
//   POST { action: "list_managers",   include_removed? }
//   POST { action: "update_manager",  user_id, full_name?, mobile?, login_id? }
//   POST { action: "set_active",      user_id, active: true | false }
//   POST { action: "reset_password",  user_id, new_password }
//   POST { action: "remove_manager",  user_id }
//
// Reply: { ok: true, action, ... }  or  { ok: false, error: "<Hinglish>", code }
// with a proper HTTP status (400 / 401 / 403 / 404 / 405 / 409 / 413 / 500 / 502).
//
// Who may call: a logged-in user whose public.users row has role "director",
// status "active" and is_active = true. Everyone else gets 403.
// Target of every change: a user whose role is "head_manager" RIGHT NOW.
// A Director, a warden ("manager"), an accountant, a pending sign-up or the
// caller himself can never be changed through this function.
//
// Every call made by a real logged-in user (allowed or refused) is written to
// public.user_admin_log (027: who, when, what, on whom, result). Only the
// Director can read it (also hidden from Managers in audit_logs). Passwords are
// never written anywhere.
//
// Login ID: "rahul01" becomes the login email rahul01@ddd-hostel.app. The app
// login box does the same mapping: input without "@" -> lower-case + trim +
// "@ddd-hostel.app"; input with "@" is used as the email.
// Mobile: 10 digits starting 6-9; +91 / 0091 / leading 0 are dropped (same rule
// as 031 Delete Duplicate: digits only, last 10, prefix only 0 / 91).
//
// No imports: only fetch() against Supabase Auth (GoTrue admin REST) and
// PostgREST, with the keys Supabase injects automatically into every Edge
// Function (SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY).
// Nothing secret is written in this file. The same file runs in Deno
// (Supabase) and in Node 22 (tests).
// =====================================================================

// ---------- settings ----------
// A plain login ID like "rahul01" becomes the login email rahul01@ddd-hostel.app
// (never emailed: the account is created already confirmed).
const LOGIN_DOMAIN = "ddd-hostel.app";
const BAN_FOREVER = "876000h"; // about 100 years = login blocked
const ROLE_DIRECTOR = "director";
const ROLE_MANAGER = "head_manager";
const PASSWORD_MIN = 8;
const PASSWORD_MAX = 72; // Supabase Auth (bcrypt) limit
const UPSTREAM_TIMEOUT_MS = 15000;
const MAX_BODY_CHARS = 8192;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const USER_COLS = "id,full_name,email,phone,status,is_active,role_id,created_at,created_by";
const ACTIONS = ["create_manager", "list_managers", "update_manager", "set_active", "reset_password", "remove_manager"];

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

// ---------- small types ----------
type Env = { url: string; anonKey: string; serviceKey: string };
type Up = { status: number; data: any };
type Roles = { byName: Map<string, string>; byId: Map<string, string> };
type Caller = { id: string; full_name: string | null; role: string | null; status: string | null; is_active: boolean | null };
type LogEntry = {
  action: string;
  target_user_id: string | null;
  target_name: string | null;
  target_login: string | null;
  details: Record<string, unknown>;
};
type Ctx = { env: Env; roles: Roles; caller: Caller; log: LogEntry };
type Result = { status?: number; data: Record<string, unknown> };

class Fail extends Error {
  status: number;
  code: string;
  constructor(status: number, message: string, code: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

// ---------- helpers: env, reply ----------
function envVar(name: string): string {
  const g = globalThis as any;
  try {
    if (g.Deno && g.Deno.env && typeof g.Deno.env.get === "function") {
      return String(g.Deno.env.get(name) ?? "");
    }
  } catch (_e) {
    // no env permission: fall through
  }
  return String((g.process && g.process.env && g.process.env[name]) ?? "");
}

function readEnv(): Env {
  const url = envVar("SUPABASE_URL").trim().replace(/\/+$/, "");
  const anonKey = envVar("SUPABASE_ANON_KEY").trim();
  const serviceKey = envVar("SUPABASE_SERVICE_ROLE_KEY").trim();
  if (!url || !anonKey || !serviceKey) {
    throw new Fail(500, "Function ki setting adhoori hai (SUPABASE_URL / keys nahi mile). Claude ko batayein.", "config");
  }
  return { url, anonKey, serviceKey };
}

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

// ---------- helpers: upstream calls (GoTrue + PostgREST) ----------
async function up(
  env: Env,
  method: string,
  path: string,
  opts: { body?: unknown; bearer?: string; apikey?: string; prefer?: string } = {},
): Promise<Up> {
  const headers: Record<string, string> = {
    apikey: opts.apikey ?? env.serviceKey,
    Authorization: "Bearer " + (opts.bearer ?? env.serviceKey),
    Accept: "application/json",
  };
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  if (opts.prefer) headers["Prefer"] = opts.prefer;
  let res: Response;
  try {
    res = await fetch(env.url + path, {
      method,
      headers,
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch (e) {
    console.error("admin-users: upstream unreachable", method, path.split("?")[0], String(e));
    throw new Fail(502, "Database / login server se jawab nahi aaya. Thodi der baad dobara try karein.", "upstream_unreachable");
  }
  const text = await res.text();
  let data: any = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (_e) {
      data = { raw: text.slice(0, 300) };
    }
  }
  return { status: res.status, data };
}

function dbFail(r: Up, what: string): Fail {
  console.error("admin-users: db error", what, r.status, JSON.stringify(r.data).slice(0, 500));
  return new Fail(500, "Database mein kaam nahi hua (" + what + "). Thodi der baad dobara try karein.", "db_error");
}

async function dbSelect(env: Env, table: string, query: string): Promise<any[]> {
  const r = await up(env, "GET", "/rest/v1/" + table + "?" + query);
  if (r.status !== 200 || !Array.isArray(r.data)) throw dbFail(r, "read " + table);
  return r.data;
}

async function dbUpsert(env: Env, table: string, rows: unknown[], onConflict: string): Promise<any[]> {
  const r = await up(env, "POST", "/rest/v1/" + table + "?on_conflict=" + onConflict, {
    body: rows,
    prefer: "resolution=merge-duplicates,return=representation",
  });
  if ((r.status !== 200 && r.status !== 201) || !Array.isArray(r.data)) throw dbFail(r, "save " + table);
  return r.data;
}

async function dbUpdate(env: Env, table: string, filter: string, patch: Record<string, unknown>): Promise<any[]> {
  const r = await up(env, "PATCH", "/rest/v1/" + table + "?" + filter, { body: patch, prefer: "return=representation" });
  if (r.status !== 200 || !Array.isArray(r.data)) throw dbFail(r, "update " + table);
  return r.data;
}

async function dbDelete(env: Env, table: string, filter: string): Promise<any[]> {
  const r = await up(env, "DELETE", "/rest/v1/" + table + "?" + filter, { prefer: "return=representation" });
  if (r.status !== 200 || !Array.isArray(r.data)) throw dbFail(r, "delete " + table);
  return r.data;
}

function authAdmin(env: Env, method: string, userId: string | null, body?: unknown): Promise<Up> {
  const path = "/auth/v1/admin/users" + (userId ? "/" + userId : "");
  return up(env, method, path, body === undefined ? {} : { body });
}

function authFail(r: Up, what: string): Fail {
  const d = r.data ?? {};
  const code = String(d.error_code ?? d.code ?? "");
  const msg = String(d.msg ?? d.message ?? d.error_description ?? d.error ?? "");
  if (code === "email_exists" || code === "user_already_exists" || /already (been )?registered|already exists/i.test(msg)) {
    return new Fail(409, "Yeh Login ID / email pehle se kisi doosre account par hai. Doosra Login ID chunein.", "login_taken");
  }
  if (code === "weak_password" || (r.status === 422 && /password/i.test(msg))) {
    return new Fail(400, "Password Supabase ne kamzor bataya (" + msg.slice(0, 120) + "). Lamba password rakhein, akshar aur ank milakar.", "weak_password");
  }
  if (code === "email_address_invalid" || (/email/i.test(msg) && /invalid|valid/i.test(msg))) {
    return new Fail(400, "Yeh Login ID / email Supabase ne nahi maana. Doosra Login ID try karein.", "bad_login");
  }
  if (r.status === 404 || code === "user_not_found") {
    return new Fail(404, "Is user ka login account Supabase mein nahi mila.", "auth_user_missing");
  }
  console.error("admin-users: auth error", what, r.status, JSON.stringify(d).slice(0, 500));
  if (/database error/i.test(msg)) {
    return new Fail(500, what + ": database ne mana kar diya. Claude ko batayein.", "auth_db_error");
  }
  return new Fail(502, what + ": login server ne mana kar diya (" + r.status + "). Thodi der baad dobara try karein.", "auth_error");
}

// ---------- helpers: input checks ----------
function reqUuid(v: unknown, field: string): string {
  const s = typeof v === "string" ? v.trim().toLowerCase() : "";
  if (!UUID_RE.test(s)) throw new Fail(400, field + " sahi nahi hai (user id chahiye).", "bad_user_id");
  return s;
}

function reqName(v: unknown): string {
  if (typeof v !== "string") throw new Fail(400, "Naam (full_name) likhein.", "bad_name");
  const s = v.normalize("NFC").replace(/\s+/g, " ").trim();
  if (s.length < 2 || s.length > 80) throw new Fail(400, "Naam 2 se 80 akshar ka hona chahiye.", "bad_name");
  // deno-lint-ignore no-control-regex
  if (/[\u0000-\u001f\u007f<>]/.test(s)) throw new Fail(400, "Naam mein < > jaise nishan nahi chalte.", "bad_name");
  return s;
}

// digits only, last 10; anything before them may only be 0 / 91 / 0091 / 910 (same rule as 031)
//   ->  10 digits starting 6-9
function reqMobile(v: unknown): string {
  if (typeof v !== "string" && typeof v !== "number") throw new Fail(400, "Mobile number likhein.", "bad_mobile");
  const all = String(v).replace(/\D/g, "");
  const d = all.length >= 10 && /^0*(91)?0*$/.test(all.slice(0, all.length - 10)) ? all.slice(-10) : "";
  if (!/^[6-9][0-9]{9}$/.test(d)) {
    throw new Fail(400, "Mobile number 10 ank ka hona chahiye (jaise 9876543210). +91 ya 0 lagana zaroori nahi.", "bad_mobile");
  }
  return d;
}

function reqLogin(v: unknown): { loginId: string; email: string } {
  const s = typeof v === "string" ? v.trim().toLowerCase() : "";
  if (s.includes("@")) {
    if (s.length > 254 || !/^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/.test(s)) {
      throw new Fail(400, "Email sahi format mein nahi hai (jaise naam@gmail.com).", "bad_login");
    }
    return { loginId: s, email: s };
  }
  if (!/^[a-z0-9][a-z0-9._-]{2,29}$/.test(s)) {
    throw new Fail(400, "Login ID 3 se 30 akshar: sirf chhote English akshar, ank, . _ - (space nahi). Ya poora email likhein.", "bad_login");
  }
  return { loginId: s, email: s + "@" + LOGIN_DOMAIN };
}

function reqPassword(v: unknown, field: string): string {
  if (typeof v !== "string" || v.length < PASSWORD_MIN) {
    throw new Fail(400, "Password kam se kam " + PASSWORD_MIN + " akshar ka rakhein (" + field + ").", "bad_password");
  }
  if (v.length > PASSWORD_MAX) throw new Fail(400, "Password " + PASSWORD_MAX + " akshar se lamba nahi ho sakta.", "bad_password");
  if (v.trim() !== v) throw new Fail(400, "Password ke shuru ya end mein space mat rakhein.", "bad_password");
  return v;
}

function loginIdFromEmail(email: string): string {
  const e = (email || "").toLowerCase();
  const suffix = "@" + LOGIN_DOMAIN;
  return e.endsWith(suffix) ? e.slice(0, -suffix.length) : e;
}

function view(u: any, a: any): Record<string, unknown> {
  const email = String((a && a.email) || u.email || "");
  const bannedUntil = a ? a.banned_until ?? null : null;
  return {
    user_id: u.id,
    full_name: u.full_name ?? null,
    mobile: u.phone ?? null,
    login_id: loginIdFromEmail(email),
    email,
    status: u.status ?? null,
    is_active: u.is_active ?? null,
    login_blocked: a ? (bannedUntil ? Date.parse(bannedUntil) > Date.now() : false) : null,
    banned_until: bannedUntil,
    last_sign_in_at: a ? a.last_sign_in_at ?? null : null,
    created_at: u.created_at ?? null,
    created_by: u.created_by ?? null,
  };
}

function needRole(ctx: Ctx, name: string): string {
  const id = ctx.roles.byName.get(name);
  if (!id) {
    throw new Fail(500, "Role '" + name + "' database mein nahi hai. Pehle 027_roles_permissions.sql chalayein.", "role_missing");
  }
  return id;
}

// ---------- who is calling ----------
async function authenticate(env: Env, req: Request): Promise<string> {
  const h = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(\S+)\s*$/i.exec(h);
  if (!m) throw new Fail(401, "Login zaroori hai. App mein dobara login karein.", "no_token");
  const token = m[1];
  if (token === env.anonKey || token === env.serviceKey) {
    throw new Fail(401, "Login zaroori hai. App mein dobara login karein.", "no_user_token");
  }
  const r = await up(env, "GET", "/auth/v1/user", { bearer: token, apikey: env.anonKey });
  if (r.status >= 500) throw new Fail(502, "Login server se jawab nahi aaya. Thodi der baad dobara try karein.", "auth_down");
  const id = String((r.data && r.data.id) ?? "").toLowerCase();
  if (r.status !== 200 || !UUID_RE.test(id)) {
    throw new Fail(401, "Login session khatam ho gaya. App mein dobara login karein.", "bad_token");
  }
  return id;
}

async function loadRoles(env: Env): Promise<Roles> {
  const rows = await dbSelect(env, "roles", "select=id,name");
  const byName = new Map<string, string>();
  const byId = new Map<string, string>();
  for (const r of rows) {
    byName.set(String(r.name), String(r.id));
    byId.set(String(r.id), String(r.name));
  }
  return { byName, byId };
}

async function loadCaller(env: Env, roles: Roles, id: string): Promise<Caller> {
  const rows = await dbSelect(env, "users", "select=id,full_name,status,is_active,role_id&id=eq." + id);
  const u = rows[0];
  if (!u) return { id, full_name: null, role: null, status: null, is_active: null };
  return {
    id,
    full_name: u.full_name ?? null,
    role: roles.byId.get(String(u.role_id)) ?? null,
    status: u.status ?? null,
    is_active: u.is_active ?? null,
  };
}

// ---------- target (the Manager being changed) ----------
async function loadTarget(ctx: Ctx, raw: unknown): Promise<any> {
  const id = reqUuid(raw, "user_id");
  ctx.log.target_user_id = id;
  if (id === ctx.caller.id) {
    throw new Fail(403, "Apna (Director ka) account is screen se nahi badla ja sakta.", "target_self");
  }
  const rows = await dbSelect(ctx.env, "users", "select=" + USER_COLS + "&id=eq." + id);
  const t = rows[0];
  if (!t) throw new Fail(404, "Yeh user nahi mila. List refresh karke dobara dekhein.", "not_found");
  ctx.log.target_name = t.full_name ?? null;
  ctx.log.target_login = t.email ?? null;
  const roleName = ctx.roles.byId.get(String(t.role_id)) ?? null;
  ctx.log.details.target_role = roleName;
  if (roleName === ROLE_DIRECTOR) {
    throw new Fail(403, "Director ka account yahan se badla ya hataya nahi ja sakta.", "target_director");
  }
  if (roleName !== ROLE_MANAGER) {
    throw new Fail(403, "Yeh user Manager nahi hai. Is screen se sirf Manager badle ja sakte hain (Warden ke liye Users screen hai).", "target_not_manager");
  }
  return t;
}

// ---------- actions ----------
async function createManager(ctx: Ctx, b: any): Promise<Result> {
  const full_name = reqName(b.full_name);
  const mobile = reqMobile(b.mobile);
  const login = reqLogin(b.login_id);
  const password = reqPassword(b.password, "password");
  const hm = needRole(ctx, ROLE_MANAGER);
  ctx.log.target_name = full_name;
  ctx.log.target_login = login.email;
  Object.assign(ctx.log.details, { full_name, mobile, login_id: login.loginId, email: login.email });

  const cr = await authAdmin(ctx.env, "POST", null, {
    email: login.email,
    password,
    email_confirm: true,
    user_metadata: { full_name, created_via: "admin-users" },
  });
  if (cr.status !== 200 && cr.status !== 201) throw authFail(cr, "Login account nahi bana");
  const authUser = cr.data && cr.data.user ? cr.data.user : cr.data;
  const newId = String((authUser && authUser.id) ?? "").toLowerCase();
  if (!UUID_RE.test(newId)) throw new Fail(502, "Login server ka jawab samajh nahi aaya. Users list check karein.", "auth_bad_reply");
  ctx.log.target_user_id = newId;

  // The sign-up trigger on auth.users may already have made a "pending" row.
  // Upsert turns it (or a missing row) into an active Manager.
  try {
    const rows = await dbUpsert(ctx.env, "users", [{
      id: newId,
      full_name,
      email: login.email,
      phone: mobile,
      role_id: hm,
      status: "active",
      is_active: true,
      created_by: ctx.caller.id,
    }], "id");
    const row = rows.find((r) => String(r.id).toLowerCase() === newId);
    if (!row || String(row.role_id) !== hm || row.status !== "active") throw new Fail(500, "profile check failed", "profile_check");
    return { status: 201, data: { manager: view(row, authUser), message: "Manager ban gaya. Login ID aur password Manager ko khud batayein." } };
  } catch (e) {
    // undo the half-made login so no orphan "pending" sign-up is left behind
    let rolledBack = false;
    try {
      const del = await authAdmin(ctx.env, "DELETE", newId);
      rolledBack = del.status >= 200 && del.status < 300;
    } catch (_e) {
      rolledBack = false;
    }
    ctx.log.details.rolled_back = rolledBack;
    ctx.log.details.cause = e instanceof Fail ? e.code : "exception";
    throw new Fail(
      500,
      rolledBack
        ? "Manager ka profile save nahi hua. Adhoora login account hata diya gaya hai. Dobara try karein."
        : "Manager ka profile save nahi hua aur adhoora login account bhi nahi hat paya (user id " + newId + "). Claude ko batayein.",
      "profile_failed",
    );
  }
}

async function listManagers(ctx: Ctx, b: any): Promise<Result> {
  const hm = needRole(ctx, ROLE_MANAGER);
  const includeRemoved = b.include_removed !== false;
  const rows = await dbSelect(ctx.env, "users", "select=" + USER_COLS + "&role_id=eq." + hm + "&order=full_name.asc");
  let removed: any[] = [];
  if (includeRemoved) {
    const logs = await dbSelect(ctx.env, "user_admin_log", "select=target_user_id&action=eq.remove_manager&ok=is.true&target_user_id=not.is.null");
    const have = new Set(rows.map((r) => String(r.id)));
    const ids = [...new Set(logs.map((l) => String(l.target_user_id)))].filter((id) => UUID_RE.test(id) && !have.has(id));
    if (ids.length) {
      removed = await dbSelect(ctx.env, "users", "select=" + USER_COLS + "&status=eq.removed&id=in.(" + ids.join(",") + ")&order=full_name.asc");
    }
  }
  const all = rows.concat(removed);
  const auth = await Promise.all(all.map(async (u) => {
    try {
      const r = await authAdmin(ctx.env, "GET", String(u.id));
      return r.status === 200 ? r.data : null;
    } catch (_e) {
      return null;
    }
  }));
  const managers = all.map((u, i) => view(u, auth[i]));
  ctx.log.details.count = rows.length;
  ctx.log.details.removed_count = removed.length;
  return { data: { managers, count: rows.length, removed_count: removed.length } };
}

async function updateManager(ctx: Ctx, b: any): Promise<Result> {
  const has = (k: string) => b[k] !== undefined && b[k] !== null;
  if (!has("full_name") && !has("mobile") && !has("login_id")) {
    throw new Fail(400, "Badalne ke liye kuch nahi diya (naam / mobile / login ID).", "nothing_to_change");
  }
  const newName = has("full_name") ? reqName(b.full_name) : null;
  const newMobile = has("mobile") ? reqMobile(b.mobile) : null;
  const newLogin = has("login_id") ? reqLogin(b.login_id) : null;
  const t = await loadTarget(ctx, b.user_id);

  const patch: Record<string, unknown> = {};
  const authPatch: Record<string, unknown> = {};
  if (newName !== null && newName !== t.full_name) {
    patch.full_name = newName;
    authPatch.user_metadata = { full_name: newName };
  }
  if (newMobile !== null && newMobile !== (t.phone ?? "")) patch.phone = newMobile;

  let authBefore: any = null;
  if (newLogin !== null || Object.keys(authPatch).length) {
    const g = await authAdmin(ctx.env, "GET", t.id);
    if (g.status !== 200) throw authFail(g, "Login account nahi mila");
    authBefore = g.data;
  }
  if (newLogin !== null) {
    const authEmail = String((authBefore && authBefore.email) || "").toLowerCase();
    if (newLogin.email !== authEmail) {
      authPatch.email = newLogin.email;
      authPatch.email_confirm = true;
    }
    if (newLogin.email !== String(t.email || "").toLowerCase()) patch.email = newLogin.email;
  }
  if (!Object.keys(patch).length && !Object.keys(authPatch).length) {
    return { data: { manager: view(t, authBefore), changed: [], message: "Kuch nahi badla (sab pehle jaisa hi hai)." } };
  }

  const before: Record<string, unknown> = {};
  for (const k of Object.keys(patch)) before[k] = t[k] ?? null;
  if (authPatch.email) before.login_email = authBefore ? authBefore.email ?? null : null;
  ctx.log.details.before = before;
  ctx.log.details.after = { ...patch, ...(authPatch.email ? { login_email: authPatch.email } : {}) };

  let authChanged = false;
  if (Object.keys(authPatch).length) {
    const r = await authAdmin(ctx.env, "PUT", t.id, authPatch);
    if (r.status !== 200) throw authFail(r, "Login details nahi badle");
    authChanged = true;
  }
  let row = t;
  if (Object.keys(patch).length) {
    try {
      const rows = await dbUpdate(ctx.env, "users", "id=eq." + t.id, patch);
      if (!rows[0]) throw new Fail(500, "no row", "no_row");
      row = rows[0];
    } catch (_e) {
      if (authChanged && authBefore) {
        const back: Record<string, unknown> = {};
        if (authPatch.email) {
          back.email = authBefore.email;
          back.email_confirm = true;
        }
        if (authPatch.user_metadata) back.user_metadata = { full_name: (authBefore.user_metadata && authBefore.user_metadata.full_name) ?? t.full_name };
        try {
          const rb = await authAdmin(ctx.env, "PUT", t.id, back);
          ctx.log.details.auth_reverted = rb.status === 200;
        } catch (_e) {
          ctx.log.details.auth_reverted = false;
        }
      }
      throw new Fail(500, "Manager ki details save nahi huin. Kuch nahi badla, dobara try karein.", "update_failed");
    }
  }
  const authNow = authChanged ? { ...authBefore, email: authPatch.email ?? authBefore.email } : authBefore;
  const changed = Object.keys(patch).concat(authPatch.email && !patch.email ? ["login_email"] : []);
  return { data: { manager: view(row, authNow), changed, message: "Manager ki details badal di gayin." } };
}

async function setActive(ctx: Ctx, b: any): Promise<Result> {
  if (typeof b.active !== "boolean") throw new Fail(400, "active sirf true ya false ho sakta hai.", "bad_active");
  const active: boolean = b.active;
  const t = await loadTarget(ctx, b.user_id);
  ctx.log.details.before = { status: t.status ?? null, is_active: t.is_active ?? null };
  ctx.log.details.active = active;

  if (active) {
    const r = await authAdmin(ctx.env, "PUT", t.id, { ban_duration: "none" });
    if (r.status !== 200) throw authFail(r, "Login chalu nahi hua");
    try {
      const rows = await dbUpdate(ctx.env, "users", "id=eq." + t.id, { status: "active", is_active: true });
      if (!rows[0]) throw new Fail(500, "no row", "no_row");
      return { data: { manager: view(rows[0], r.data), message: "Manager ka login chalu kar diya gaya." } };
    } catch (_e) {
      try {
        await authAdmin(ctx.env, "PUT", t.id, { ban_duration: BAN_FOREVER });
      } catch (_e2) {
        // nothing more we can do; the reply tells the Director to retry
      }
      throw new Fail(500, "Profile update nahi hua, isliye login phir se band rakha gaya. Dobara try karein.", "activate_failed");
    }
  }

  // deactivate: block the login first (safe side), then mark the profile
  const r = await authAdmin(ctx.env, "PUT", t.id, { ban_duration: BAN_FOREVER });
  if (r.status !== 200) throw authFail(r, "Login band nahi hua");
  let rows: any[];
  try {
    rows = await dbUpdate(ctx.env, "users", "id=eq." + t.id, { status: "inactive", is_active: false });
    if (!rows[0]) throw new Fail(500, "no row", "no_row");
  } catch (_e) {
    throw new Fail(500, "Login band ho gaya hai par profile update nahi hua. Dobara Deactivate dabayein.", "deactivate_partial");
  }
  return { data: { manager: view(rows[0], r.data), message: "Manager ka login band kar diya gaya." } };
}

async function resetPassword(ctx: Ctx, b: any): Promise<Result> {
  const pw = reqPassword(b.new_password, "new_password");
  const t = await loadTarget(ctx, b.user_id);
  const r = await authAdmin(ctx.env, "PUT", t.id, { password: pw });
  if (r.status !== 200) throw authFail(r, "Password nahi badla");
  ctx.log.details.password_changed = true;
  return { data: { user_id: t.id, message: "Password badal diya gaya. Naya password Manager ko khud batayein." } };
}

async function removeManager(ctx: Ctx, b: any): Promise<Result> {
  const t = await loadTarget(ctx, b.user_id);
  ctx.log.details.before = {
    full_name: t.full_name ?? null,
    email: t.email ?? null,
    phone: t.phone ?? null,
    status: t.status ?? null,
    is_active: t.is_active ?? null,
    role: ROLE_MANAGER,
  };
  // 1. block the login for good (the auth account is KEPT so history keeps the name)
  const r = await authAdmin(ctx.env, "PUT", t.id, {
    ban_duration: BAN_FOREVER,
    user_metadata: { removed_at: new Date().toISOString(), removed_by: ctx.caller.id },
  });
  if (r.status !== 200) throw authFail(r, "Login band nahi hua");
  // 2. drop hostel links (if any), 3. mark the profile removed and take the role away.
  // Step 3 is last, so a retry after a half-failure still finds role head_manager.
  try {
    const gone = await dbDelete(ctx.env, "user_hostel_assignments", "user_id=eq." + t.id);
    ctx.log.details.hostel_links_removed = gone.map((a) => a.hostel_id ?? null);
    const rows = await dbUpdate(ctx.env, "users", "id=eq." + t.id, { status: "removed", is_active: false, role_id: null });
    if (!rows[0]) throw new Fail(500, "no row", "no_row");
    return { data: { manager: view(rows[0], r.data), message: "Manager hata diya gaya. Login band hai, purana record history ke liye rakha gaya hai." } };
  } catch (_e) {
    throw new Fail(500, "Login band ho gaya hai par profile poora update nahi hua. Dobara Remove dabayein.", "remove_partial");
  }
}

const HANDLERS: Record<string, (ctx: Ctx, b: any) => Promise<Result>> = {
  create_manager: createManager,
  list_managers: listManagers,
  update_manager: updateManager,
  set_active: setActive,
  reset_password: resetPassword,
  remove_manager: removeManager,
};

// ---------- log ----------
async function writeLog(
  env: Env,
  caller: Caller,
  entry: LogEntry,
  outcome: { ok: boolean; status: number; error: string | null },
  meta: { ip: string | null; ua: string | null },
): Promise<boolean> {
  const row = {
    actor_id: caller.id,
    actor_name: caller.full_name,
    actor_role: caller.role,
    action: entry.action,
    target_user_id: entry.target_user_id,
    target_name: entry.target_name,
    target_login: entry.target_login,
    ok: outcome.ok,
    http_status: outcome.status,
    error: outcome.error,
    details: entry.details,
    ip: meta.ip,
    user_agent: meta.ua,
  };
  try {
    const r = await up(env, "POST", "/rest/v1/user_admin_log", { body: row, prefer: "return=minimal" });
    if (r.status >= 200 && r.status < 300) return true;
    console.error("admin-users: log insert failed", r.status, JSON.stringify(r.data).slice(0, 300));
  } catch (e) {
    console.error("admin-users: log insert failed", String(e));
  }
  return false;
}

function cleanAction(v: unknown): string {
  if (typeof v !== "string") return "unknown";
  return /^[a-z_]{1,40}$/.test(v) ? v : "unknown";
}

// ---------- main ----------
export async function handleRequest(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: CORS_HEADERS });
  if (req.method !== "POST") return reply(405, { ok: false, error: "Sirf POST request chalti hai.", code: "method" });

  const meta = {
    ip: (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim().slice(0, 64) || null,
    ua: (req.headers.get("user-agent") ?? "").slice(0, 200) || null,
  };
  let env: Env | null = null;
  let caller: Caller | null = null;
  const log: LogEntry = { action: "unknown", target_user_id: null, target_name: null, target_login: null, details: {} };

  try {
    env = readEnv();
    const callerId = await authenticate(env, req);

    // body is read before the role check only to record WHAT was attempted
    let body: any = null;
    let bodyError: Fail | null = null;
    try {
      const text = await req.text();
      if (text.length > MAX_BODY_CHARS) {
        bodyError = new Fail(413, "Request bahut badi hai.", "too_large");
      } else {
        body = text ? JSON.parse(text) : null;
        if (!body || typeof body !== "object" || Array.isArray(body)) {
          bodyError = new Fail(400, "Request mein { action: ... } chahiye.", "bad_json");
          body = null;
        }
      }
    } catch (_e) {
      bodyError = new Fail(400, "Request ka JSON sahi nahi hai.", "bad_json");
      body = null;
    }
    log.action = cleanAction(body ? body.action : null);
    if (body && log.action === "unknown" && body.action !== undefined) log.details.requested_action = String(body.action).slice(0, 40);

    const roles = await loadRoles(env);
    caller = await loadCaller(env, roles, callerId);
    if (!(caller.role === ROLE_DIRECTOR && caller.status === "active" && caller.is_active === true)) {
      throw new Fail(403, "Yeh kaam sirf Director kar sakte hain.", "not_director");
    }
    if (bodyError) throw bodyError;
    // sirf apne handlers (constructor / __proto__ jaise object ke naam kabhi action nahi)
    const fn = Object.prototype.hasOwnProperty.call(HANDLERS, log.action) ? HANDLERS[log.action] : null;
    if (!fn) throw new Fail(400, "Anjaan action. Sahi action: " + ACTIONS.join(", ") + ".", "bad_action");

    const ctx: Ctx = { env, roles, caller, log };
    const res = await fn(ctx, body);
    const status = res.status ?? 200;
    const saved = await writeLog(env, caller, log, { ok: true, status, error: null }, meta);
    const out: Record<string, unknown> = { ok: true, action: log.action, ...res.data };
    if (!saved) out.log_warning = "Kaam ho gaya, par log save nahi hua. Claude ko batayein.";
    return reply(status, out);
  } catch (e) {
    let f: Fail;
    if (e instanceof Fail) {
      f = e;
    } else {
      console.error("admin-users: unexpected", String(e && (e as any).stack ? (e as any).stack : e));
      f = new Fail(500, "Andar koi gadbad hui. Thodi der baad dobara try karein.", "internal");
    }
    // 401 (no real login) is not logged: anyone with the public anon key could fill the log
    if (env && caller && f.status !== 401) {
      await writeLog(env, caller, log, { ok: false, status: f.status, error: f.message }, meta);
    }
    return reply(f.status, { ok: false, error: f.message, code: f.code });
  }
}

// Supabase (Deno) entry point. In Node (tests) Deno is undefined and this is skipped.
const DenoNS = (globalThis as any).Deno;
if (DenoNS && typeof DenoNS.serve === "function") {
  DenoNS.serve(handleRequest);
}
