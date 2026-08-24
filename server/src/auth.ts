// 认证：注册/登录 + HMAC-JWT。密码用 node:crypto scrypt 哈希（零外部依赖）。
// 注意：聊天内容本身按需求明文存储，但密码仍需哈希。

import { createHmac, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';

const SECRET = process.env.JWT_SECRET ?? 'dev-secret-change-me';
const TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 天

// ---- 密码哈希 ----

export function hashPassword(password: string): string {
  const salt = randomBytes(16).toString('hex');
  const hash = scryptSync(password, salt, 64).toString('hex');
  return `${salt}:${hash}`;
}

export function verifyPassword(password: string, stored: string): boolean {
  const [salt, hash] = stored.split(':');
  if (!salt || !hash) return false;
  const candidate = scryptSync(password, salt, 64);
  const expected = Buffer.from(hash, 'hex');
  return candidate.length === expected.length && timingSafeEqual(candidate, expected);
}

// ---- HMAC-JWT（不依赖 jsonwebtoken） ----

function b64url(buf: Buffer): string {
  return buf.toString('base64url');
}

export function signToken(subject: string): string {
  const header = b64url(Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })));
  const payload = b64url(
    Buffer.from(JSON.stringify({ sub: subject, exp: Date.now() + TOKEN_TTL_MS })),
  );
  const sig = createHmac('sha256', SECRET).update(`${header}.${payload}`).digest();
  return `${header}.${payload}.${b64url(sig)}`;
}

/** 校验 token，成功返回用户名（subject），失败返回 null。 */
export function verifyToken(token: string): string | null {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [header, payload, sig] = parts;
  const expected = createHmac('sha256', SECRET).update(`${header}.${payload}`).digest();
  let given: Buffer;
  try {
    given = Buffer.from(sig, 'base64url');
  } catch {
    return null;
  }
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) {
    return null;
  }
  try {
    const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as {
      sub?: string;
      exp?: number;
    };
    if (typeof data.exp === 'number' && data.exp < Date.now()) return null;
    return typeof data.sub === 'string' ? data.sub : null;
  } catch {
    return null;
  }
}
