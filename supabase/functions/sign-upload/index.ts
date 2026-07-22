// sign-upload — выдача подписи Cloudinary аутентифицированному actor (T10-09, SPEC_T10 §§3-4).
//
// Заменяет unsigned upload_preset у ученика (фото ДЗ) и учителя (PDF задания). Подпись выдаётся
// только по валидному ES256 JWT нашего выпуска (проверяется по JWKS проекта, приватный ключ здесь
// не нужен) и только для назначения, разрешённого этому actor:
//   student  -> kind=student_photo, folder sasha-math-dz, только СВОЁ assignment (owner-проверка в БД);
//   teacher  -> kind=teacher_pdf,  folder sasha-math-tasks.
// Сервер сам определяет folder, public_id, resource_type, allowed_formats и timestamp; клиент не
// передаёт ни preset, ни folder, ни public_id. CLOUDINARY_API_SECRET — только Edge secret,
// наружу и в лог не попадает (в ответе только подпись, api_key и параметры).
//
// Развёртывать как student-auth: --no-verify-jwt (проверка JWT выполняется внутри функции).

import { corsHeaders, originAllowed } from "../_shared/cors.ts";
import { AuthError, json, safeError, tagAuditLine } from "../_shared/errors.ts";
import { verifyJwtES256 } from "../_shared/jwt.ts";
import { assignmentOwnedBy, rateLimitHit } from "../_shared/db.ts";
import {
  assertAssignmentId,
  assertBytes,
  assertFormat,
  buildPublicId,
  policyFor,
  signParams,
  uploadParams,
} from "../_shared/cloudinary.ts";

const CLOUD_NAME = Deno.env.get("CLOUDINARY_CLOUD_NAME") ?? "";
const API_KEY = Deno.env.get("CLOUDINARY_API_KEY") ?? "";
const API_SECRET = Deno.env.get("CLOUDINARY_API_SECRET") ?? "";
// Необязательный ПОДПИСАННЫЙ preset (signing mode = signed) с max_file_size в консоли Cloudinary —
// единственный способ жёстко ограничить размер на стороне Cloudinary. Имя приходит из secret и
// входит в подпись, поэтому клиент его подменить не может.
const SIGNED_PRESET = Deno.env.get("CLOUDINARY_SIGNED_PRESET") ?? "";
const JWT_ISS = Deno.env.get("JWT_ISS") ?? `${Deno.env.get("SUPABASE_URL") ?? ""}/auth/v1`;

const MAX_BODY_BYTES = 4 * 1024; // 4 KB — тело только метаданные, файл сюда не приходит
const RL_BUCKET = "sign_upload";
const RL_MAX = Number(Deno.env.get("SIGN_UPLOAD_RL_MAX") ?? "120");
const RL_WINDOW_SEC = Number(Deno.env.get("SIGN_UPLOAD_RL_WINDOW_SEC") ?? "300");
// Cloudinary отвергает подпись со слишком старым timestamp (окно ~1 час); клиенту сообщаем более
// короткий собственный срок, чтобы протухшая подпись не висела в UI.
const SIGNATURE_TTL_SEC = 10 * 60;

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);

  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405, cors);
  if (!originAllowed(origin)) return json({ error: "origin_not_allowed" }, 403, cors);

  const raw = new Uint8Array(await req.arrayBuffer());
  if (raw.byteLength > MAX_BODY_BYTES) return json({ error: "body_too_large" }, 413, cors);

  try {
    if (!CLOUD_NAME || !API_KEY || !API_SECRET) throw new AuthError("server_misconfigured", 500);

    const auth = req.headers.get("authorization") ?? "";
    const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
    if (!token) throw new AuthError("unauthorized", 401);

    let claims;
    try {
      claims = await verifyJwtES256(token, { issuer: JWT_ISS, audience: "authenticated" });
    } catch (e) {
      throw new AuthError((e as Error).message === "token_expired" ? "token_expired" : "unauthorized", 401);
    }

    let body: Record<string, unknown>;
    try {
      body = JSON.parse(new TextDecoder().decode(raw)) ?? {};
    } catch {
      throw new AuthError("bad_request", 400);
    }

    // Политика по kind + жёсткая привязка kind к роли: ученик не получит teacher folder.
    let policy;
    try {
      policy = policyFor(body.kind);
    } catch {
      throw new AuthError("bad_request", 400);
    }
    if (claims.app_role !== policy.appRole) throw new AuthError("forbidden", 403);

    try {
      assertFormat(body.filename, policy);
      assertBytes(body.bytes, policy);
    } catch (e) {
      const code = (e as Error).message;
      throw new AuthError(code === "file_too_large" ? "file_too_large" : "bad_request", code === "file_too_large" ? 413 : 400);
    }

    // Rate limit по principal (не по IP): подпись выдаётся только известному actor.
    const allowed = await rateLimitHit(RL_BUCKET, claims.sub, RL_MAX, RL_WINDOW_SEC);
    if (!allowed) throw new AuthError("rate_limited", 429);

    let assignmentId: string | null = null;
    let actorKey: string;

    if (policy.needsAssignment) {
      try {
        assignmentId = assertAssignmentId(body.assignment_id);
      } catch {
        throw new AuthError("bad_request", 400);
      }
      const telegramId = Number(claims.telegram_id);
      if (!Number.isInteger(telegramId) || telegramId <= 0) throw new AuthError("unauthorized", 401);
      // Чужое или несуществующее задание — одинаковый отказ, существование не раскрываем.
      if (!(await assignmentOwnedBy(telegramId, assignmentId))) throw new AuthError("forbidden", 403);
      actorKey = String(telegramId);
    } else {
      actorKey = String(claims.teacher_id ?? claims.sub);
    }

    const timestamp = Math.floor(Date.now() / 1000);
    const publicId = buildPublicId(policy, actorKey, assignmentId, crypto.randomUUID());
    const params = uploadParams(policy, publicId, timestamp, SIGNED_PRESET || undefined);
    const signature = await signParams(params, API_SECRET);

    console.log(tagAuditLine("sign-upload", "signed", policy.kind));
    return json({
      cloud_name: CLOUD_NAME,
      api_key: API_KEY,
      resource_type: policy.resourceType,
      params, // ровно то, что подписано: folder, public_id, allowed_formats, overwrite, timestamp
      signature,
      expires_in: SIGNATURE_TTL_SEC,
      max_bytes: policy.maxBytes,
    }, 200, cors);
  } catch (e) {
    const { code, status } = safeError(e);
    console.log(tagAuditLine("sign-upload", "rejected", code)); // без токена/секрета/подписи
    return json({ error: code }, status, cors);
  }
});
