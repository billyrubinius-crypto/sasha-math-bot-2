// deno test supabase/functions/tests/sign_upload_test.ts
// Unit-тесты политики загрузок и подписи Cloudinary + проверки claims (T10-09).
// Сеть/секреты не нужны: тестируется чистая логика, из которой собран sign-upload.

import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  assertAssignmentId,
  assertBytes,
  assertFormat,
  buildPublicId,
  POLICIES,
  policyFor,
  signatureBase,
  signParams,
  uploadParams,
} from "../_shared/cloudinary.ts";
import { assertClaims, type VerifiedClaims } from "../_shared/jwt.ts";

const ASSIGNMENT = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";

Deno.test("policyFor: только известные kind; folder/тип зафиксированы сервером", () => {
  assertEquals(policyFor("student_photo").folder, "sasha-math-dz");
  assertEquals(policyFor("student_photo").appRole, "student");
  assertEquals(policyFor("teacher_pdf").folder, "sasha-math-tasks");
  assertEquals(policyFor("teacher_pdf").appRole, "teacher");
  assertThrows(() => policyFor("anything_else"));
  assertThrows(() => policyFor(undefined));
});

Deno.test("роли не пересекаются: student-политика не ведёт в teacher folder и наоборот", () => {
  // Ученик может запросить только student_photo — teacher_pdf требует app_role=teacher.
  assertEquals(POLICIES.teacher_pdf.appRole, "teacher");
  assertEquals(POLICIES.student_photo.appRole, "student");
  assert(POLICIES.student_photo.folder !== POLICIES.teacher_pdf.folder);
});

Deno.test("формат: allowlist по политике", () => {
  const s = POLICIES.student_photo;
  assertEquals(assertFormat("photo.JPG", s), "jpg");
  assertEquals(assertFormat("scan.heic", s), "heic");
  assertThrows(() => assertFormat("payload.pdf", s), Error, "format_not_allowed");
  assertThrows(() => assertFormat("payload.svg", s), Error, "format_not_allowed");
  assertThrows(() => assertFormat("noext", s), Error, "format_not_allowed");

  const t = POLICIES.teacher_pdf;
  assertEquals(assertFormat("tasks.pdf", t), "pdf");
  assertThrows(() => assertFormat("tasks.png", t), Error, "format_not_allowed");
});

Deno.test("размер: положительное целое в пределах политики", () => {
  const s = POLICIES.student_photo;
  assertEquals(assertBytes(1024, s), 1024);
  assertThrows(() => assertBytes(s.maxBytes + 1, s), Error, "file_too_large");
  assertThrows(() => assertBytes(0, s), Error, "bad_bytes");
  assertThrows(() => assertBytes(-5, s), Error, "bad_bytes");
  assertThrows(() => assertBytes("1024", s), Error, "bad_bytes");
});

Deno.test("assignment_id: только UUID", () => {
  assertEquals(assertAssignmentId(ASSIGNMENT), ASSIGNMENT);
  assertThrows(() => assertAssignmentId("1 or 1=1"), Error, "bad_assignment_id");
  assertThrows(() => assertAssignmentId(""), Error, "bad_assignment_id");
});

Deno.test("public_id полностью серверный: actor-скоуп, без клиентских строк", () => {
  const id = buildPublicId(POLICIES.student_photo, "123456", ASSIGNMENT, "rnd");
  assertEquals(id, `s123456/${ASSIGNMENT}/rnd`);
  // Попытка вырваться из префикса через actorKey не проходит — недопустимые символы срезаются.
  const evil = buildPublicId(POLICIES.student_photo, "../../sasha-math-tasks", ASSIGNMENT, "rnd");
  assert(!evil.includes(".."));
  assert(!evil.includes("/sasha-math-tasks"));
  assertEquals(buildPublicId(POLICIES.teacher_pdf, "sasha", null, "rnd"), "tsasha/rnd");
});

Deno.test("подписываются folder/public_id/allowed_formats/overwrite/timestamp", () => {
  const p = uploadParams(POLICIES.student_photo, "s1/a/b", 1700000000);
  assertEquals(Object.keys(p).sort(), [
    "allowed_formats",
    "folder",
    "overwrite",
    "public_id",
    "timestamp",
  ]);
  assertEquals(p.overwrite, "false");
  assertEquals(p.folder, "sasha-math-dz");
  // upload_preset появляется, только если owner задал ПОДПИСАННЫЙ preset в Edge secret.
  assertEquals(uploadParams(POLICIES.teacher_pdf, "t1/b", 1, "signed-preset").upload_preset, "signed-preset");
});

Deno.test("signatureBase: сортировка по имени и склейка k=v через &", () => {
  assertEquals(
    signatureBase({ timestamp: "2", folder: "f", allowed_formats: "pdf" }),
    "allowed_formats=pdf&folder=f&timestamp=2",
  );
});

Deno.test("signParams: SHA-1 hex от base+secret (контракт Cloudinary)", async () => {
  // Контрольный вектор: sha1("public_id=sample_image&timestamp=1315060510" + "abcd") —
  // ровно та строка, которую Cloudinary соберёт на своей стороне.
  const sig = await signParams(
    { public_id: "sample_image", timestamp: "1315060510" },
    "abcd",
  );
  assertEquals(sig, "b4ad47fb4e25c7bf5f92a20089f9db59bc302313");
  // Тот же набор параметров с другим секретом даёт другую подпись.
  const other = await signParams({ public_id: "sample_image", timestamp: "1315060510" }, "abce");
  assert(sig !== other);
});

Deno.test("подпись зависит от каждого ограничивающего параметра", async () => {
  const base = uploadParams(POLICIES.student_photo, "s1/a/b", 1700000000);
  const sig = await signParams(base, "secret");
  const movedFolder = await signParams({ ...base, folder: "sasha-math-tasks" }, "secret");
  const widenedFormats = await signParams({ ...base, allowed_formats: "pdf,jpg" }, "secret");
  const otherTs = await signParams({ ...base, timestamp: "1700000001" }, "secret");
  assert(sig !== movedFolder, "folder входит в подпись");
  assert(sig !== widenedFormats, "allowed_formats входит в подпись");
  assert(sig !== otherTs, "timestamp входит в подпись");
});

// --- claims-гейт sign-upload -------------------------------------------------------------------
function claims(over: Partial<VerifiedClaims> = {}): VerifiedClaims {
  return {
    role: "authenticated",
    app_role: "student",
    sub: "9c1b6f1e-0000-4000-8000-000000000001",
    telegram_id: "123456",
    aud: "authenticated",
    iss: "https://example.supabase.co/auth/v1",
    iat: 1700000000,
    exp: 1700003600,
    ...over,
  } as VerifiedClaims;
}
const OPTS = { now: 1700000100, audience: "authenticated", issuer: "https://example.supabase.co/auth/v1" };

Deno.test("assertClaims: валидный student/teacher токен принимается", () => {
  assertClaims(claims(), OPTS);
  assertClaims(claims({ app_role: "teacher", teacher_id: "sasha", telegram_id: undefined }), OPTS);
});

Deno.test("assertClaims: протухший токен отвергается", () => {
  assertThrows(() => assertClaims(claims({ exp: 1699999000 }), OPTS), Error, "token_expired");
});

Deno.test("assertClaims: чужой aud/iss, не та role, кривой app_role и telegram_id отвергаются", () => {
  assertThrows(() => assertClaims(claims({ aud: "other" }), OPTS), Error, "bad_token");
  assertThrows(() => assertClaims(claims({ iss: "https://evil.example" }), OPTS), Error, "bad_token");
  assertThrows(() => assertClaims(claims({ role: "service_role" }), OPTS), Error, "bad_token");
  assertThrows(() => assertClaims(claims({ app_role: "admin" as never }), OPTS), Error, "bad_token");
  assertThrows(() => assertClaims(claims({ telegram_id: "abc" }), OPTS), Error, "bad_token");
  assertThrows(() => assertClaims(claims({ telegram_id: undefined }), OPTS), Error, "bad_token");
  assertThrows(() => assertClaims(claims({ sub: "" }), OPTS), Error, "bad_token");
});
