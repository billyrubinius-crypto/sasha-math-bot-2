// _shared/cloudinary.ts — политика загрузок и подпись Cloudinary (T10-09, SPEC_T10 §§3-4).
//
// Здесь только чистая логика: какой actor что имеет право грузить, куда, каким форматом и какого
// размера, и как из разрешённых параметров собирается официальная подпись Cloudinary
// (отсортированные params + api_secret -> SHA-1 hex). API secret приходит аргументом из Edge
// secret, в этот модуль не зашит и никогда не логируется/не возвращается наружу.

export type UploadKind = "student_photo" | "teacher_pdf";

export interface UploadPolicy {
  kind: UploadKind;
  appRole: "student" | "teacher";
  folder: string;
  resourceType: "image" | "auto";
  allowedFormats: string[];
  maxBytes: number;
  needsAssignment: boolean;
}

// Folder/resource_type/формат/размер задаёт сервер, клиент не может их подменить: folder и
// allowed_formats входят в подпись, public_id генерируется целиком здесь.
export const POLICIES: Record<UploadKind, UploadPolicy> = {
  // Ученик: фото ДЗ, тот же folder, что и до T10-09 (существующие ссылки не ломаются).
  student_photo: {
    kind: "student_photo",
    appRole: "student",
    folder: "sasha-math-dz",
    resourceType: "image",
    allowedFormats: ["jpg", "jpeg", "png", "heic", "heif", "webp"],
    maxBytes: 12 * 1024 * 1024,
    needsAssignment: true,
  },
  // Учитель: PDF задания. resourceType 'auto' сохраняет прежний вид ссылок (Cloudinary кладёт
  // PDF как image), allowed_formats: ['pdf'] — жёсткое серверное ограничение содержимого.
  teacher_pdf: {
    kind: "teacher_pdf",
    appRole: "teacher",
    folder: "sasha-math-tasks",
    resourceType: "auto",
    allowedFormats: ["pdf"],
    maxBytes: 25 * 1024 * 1024,
    needsAssignment: false,
  },
};

export function policyFor(kind: unknown): UploadPolicy {
  if (typeof kind !== "string" || !(kind in POLICIES)) throw new Error("bad_kind");
  return POLICIES[kind as UploadKind];
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function assertAssignmentId(value: unknown): string {
  if (typeof value !== "string" || !UUID_RE.test(value)) throw new Error("bad_assignment_id");
  return value;
}

// Заявленный клиентом размер: должен быть положительным целым в пределах политики. Это первый
// рубеж; жёсткое серверное усечение даёт signed preset с max_file_size (см. CLOUDINARY_SIGNED_PRESET).
export function assertBytes(value: unknown, policy: UploadPolicy): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) throw new Error("bad_bytes");
  if (value > policy.maxBytes) throw new Error("file_too_large");
  return value;
}

// Формат берётся из имени файла и обязан входить в allowlist политики (Cloudinary дополнительно
// отвергнет несовпадение по подписанному allowed_formats).
export function assertFormat(filename: unknown, policy: UploadPolicy): string {
  if (typeof filename !== "string" || filename.length === 0 || filename.length > 200) {
    throw new Error("bad_filename");
  }
  const ext = filename.split(".").pop()?.toLowerCase() ?? "";
  if (!policy.allowedFormats.includes(ext)) throw new Error("format_not_allowed");
  return ext;
}

// public_id (без folder — Cloudinary склеит folder/public_id). Полностью серверный: actor-скоуп
// в пути, случайный хвост, никаких клиентских строк.
export function buildPublicId(
  policy: UploadPolicy,
  actorKey: string,
  assignmentId: string | null,
  random: string,
): string {
  const safeActor = actorKey.replace(/[^0-9a-zA-Z_-]/g, "").slice(0, 40) || "unknown";
  return policy.kind === "student_photo"
    ? `s${safeActor}/${assignmentId}/${random}`
    : `t${safeActor}/${random}`;
}

// Официальный контракт Cloudinary: параметры (кроме file, api_key, resource_type, cloud_name)
// сортируются по имени, склеиваются k=v через '&', в конец дописывается api_secret, берётся SHA-1.
export function signatureBase(params: Record<string, string>): string {
  return Object.keys(params)
    .sort()
    .map((k) => `${k}=${params[k]}`)
    .join("&");
}

export async function signParams(
  params: Record<string, string>,
  apiSecret: string,
): Promise<string> {
  const data = new TextEncoder().encode(signatureBase(params) + apiSecret);
  const digest = await crypto.subtle.digest("SHA-1", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Подписываемые параметры загрузки. overwrite=false запрещает перезапись чужого/существующего
// объекта, allowed_formats и folder фиксируют тип и место, timestamp даёт окно годности.
export function uploadParams(
  policy: UploadPolicy,
  publicId: string,
  timestamp: number,
  signedPreset?: string,
): Record<string, string> {
  const params: Record<string, string> = {
    allowed_formats: policy.allowedFormats.join(","),
    folder: policy.folder,
    overwrite: "false",
    public_id: publicId,
    timestamp: String(timestamp),
  };
  if (signedPreset) params.upload_preset = signedPreset;
  return params;
}
