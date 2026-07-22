// _shared/secret.ts — константное по времени сравнение статичного bot-секрета (T10-10A).
// В отличие от telegram.ts/password.ts (сравнение уже готовых hex-хэшей/PBKDF2-выводов равной
// длины), здесь секрет и присланное значение могут отличаться длиной — сначала оба хэшируются
// до фиксированных 32 байт (SHA-256), только потом сравниваются побайтово. Это не даёт длине
// присланной строки протечь через раннее сравнение до хэширования.

export async function constantTimeSecretEqual(provided: string, expected: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(provided)),
    crypto.subtle.digest("SHA-256", enc.encode(expected)),
  ]);
  const ba = new Uint8Array(a);
  const bb = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < ba.length; i++) diff |= ba[i] ^ bb[i];
  return diff === 0;
}
