import { createClient } from 'npm:@supabase/supabase-js@2.57.4';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = getServiceKey();
const RATE_LIMIT_SALT = Deno.env.get('HOPA_RATE_LIMIT_SALT') ?? '';
const ALLOWED_ORIGINS = (Deno.env.get('HOPA_ALLOWED_ORIGINS') ?? '*')
  .split(',').map((v) => v.trim()).filter(Boolean);
const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});

function getServiceKey(): string {
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (legacy) return legacy;
  try {
    const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}') as Record<string, string>;
    // Supabase's modern generated secret is normally named `default`.
    if (typeof keys.default === 'string' && keys.default) return keys.default;
    const entry = Object.entries(keys).find(([name]) => /service.?role/i.test(name));
    if (entry?.[1]) return entry[1];
    const values = Object.values(keys);
    if (values.length === 1 && values[0]) return values[0];
  } catch (_) { /* reported below with a generic server error */ }
  throw new Error('Supabase service-role key is not available in the Edge Function environment.');
}

function corsHeaders(origin: string | null): HeadersInit {
  const originAllowed = ALLOWED_ORIGINS.includes('*') || (!!origin && ALLOWED_ORIGINS.includes(origin));
  return {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.includes('*') ? '*' : (originAllowed ? origin! : 'null'),
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  };
}

function jsonResponse(body: unknown, status: number, headers: HeadersInit): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function normalizeDigits(value: string): string {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const eastern = '۰۱۲۳۴۵۶۷۸۹';
  return [...value].map((ch) => {
    const a = arabic.indexOf(ch);
    if (a >= 0) return String(a);
    const e = eastern.indexOf(ch);
    if (e >= 0) return String(e);
    return ch;
  }).join('').replace(/[^0-9]/g, '');
}

function isHexSecret(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-fA-F]{64}$/.test(value);
}

function ipAddress(req: Request): string {
  // Prefer a proxy-populated address header. Do not trust arbitrary X-Forwarded-For input,
  // which a caller can forge on some hosting paths to rotate rate-limit identities.
  return req.headers.get('cf-connecting-ip')?.trim()
    || req.headers.get('x-real-ip')?.trim()
    || 'unknown';
}

async function rateLimit(req: Request, action: 'create' | 'track' | 'update' | 'cancel') {
  if (!RATE_LIMIT_SALT || RATE_LIMIT_SALT.length < 32) {
    throw new Error('HOPA_RATE_LIMIT_SALT must be configured with at least 32 random characters.');
  }
  const ipHash = await sha256Hex(`${RATE_LIMIT_SALT}:${ipAddress(req)}`);
  const limits: Record<typeof action, number> = { create: 5, track: 20, update: 8, cancel: 8 };
  const { data, error } = await admin.rpc('consume_hopa_rate_limit', {
    p_ip_hash: ipHash,
    p_action: action,
    p_window_seconds: 900,
    p_max_requests: limits[action],
  });
  if (error) throw new Error('Rate-limit service unavailable.');
  return data === true;
}

function cleanText(value: unknown, maxLength: number): string {
  return typeof value === 'string' ? value.trim().slice(0, maxLength) : '';
}

function escapeHtml(value: unknown): string {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[ch]!);
}

async function verifyTurnstile(token: unknown, req: Request): Promise<boolean> {
  const secret = Deno.env.get('HOPA_TURNSTILE_SECRET');
  if (!secret) return true; // Enable server-side CAPTCHA verification by setting the secret.
  if (typeof token !== 'string' || token.length < 10 || token.length > 4096) return false;
  const form = new URLSearchParams({ secret, response: token });
  const ip = ipAddress(req);
  if (ip && ip !== 'unknown') form.set('remoteip', ip);
  const response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: form,
  });
  if (!response.ok) return false;
  const result = await response.json() as { success?: boolean; hostname?: string };
  const expectedHostname = Deno.env.get('HOPA_TURNSTILE_HOSTNAME')?.trim().toLowerCase();
  if (!result.success) return false;
  if (expectedHostname && String(result.hostname ?? '').toLowerCase() !== expectedHostname) return false;
  return true;
}

async function sendAdminEmail(order: Record<string, unknown>) {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  const to = Deno.env.get('HOPA_NOTIFICATION_EMAIL');
  const from = Deno.env.get('HOPA_NOTIFICATION_FROM');
  if (!apiKey || !to || !from) return;
  const items = Array.isArray(order.items) ? order.items as Array<Record<string, unknown>> : [];
  const itemRows = items.map((item) => `<tr><td style="padding:8px;border-bottom:1px solid #eee">${escapeHtml(item.product_name)} — ${escapeHtml(item.size)} × ${escapeHtml(item.quantity)}</td><td style="padding:8px;border-bottom:1px solid #eee;text-align:left">${escapeHtml(item.line_total)} ج.م</td></tr>`).join('');
  const html = `<div dir="rtl" style="font-family:Arial,sans-serif;color:#211f20;max-width:650px;margin:auto"><h2 style="color:#ed1c24">طلب جديد من هوبا بيتزا</h2><p><b>رقم الطلب:</b> ${escapeHtml(order.order_number)}</p><p><b>العميل:</b> ${escapeHtml(order.customer_name)}</p><p><b>الهاتف:</b> ${escapeHtml(order.phone)}</p><p><b>العنوان:</b> ${escapeHtml(order.address)}</p><table style="width:100%;border-collapse:collapse"><thead><tr><th style="text-align:right">الصنف</th><th style="text-align:left">الإجمالي</th></tr></thead><tbody>${itemRows}</tbody></table><p>قيمة الأصناف: <b>${escapeHtml(order.subtotal)} ج.م</b></p><p>التوصيل: <b>${escapeHtml(order.delivery_fee)} ج.م</b></p><h3>الإجمالي: ${escapeHtml(order.total)} ج.م</h3><p>ملاحظات: ${escapeHtml(order.notes || 'لا توجد')}</p></div>`;
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to: [to], subject: `طلب جديد ${String(order.order_number ?? '')} — هوبا بيتزا`, html }),
  });
  if (!response.ok) console.error('[Hopa notification] Email provider returned status', response.status);
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin');
  const headers = corsHeaders(origin);
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers });
  if (req.method !== 'POST') return jsonResponse({ ok: false, error: 'طريقة الطلب غير مدعومة.' }, 405, headers);
  if (!ALLOWED_ORIGINS.includes('*') && (!origin || !ALLOWED_ORIGINS.includes(origin))) {
    return jsonResponse({ ok: false, error: 'مصدر الطلب غير مسموح.' }, 403, headers);
  }
  // The endpoint is public by design (order placement/tracking), but still require this project's
  // publishable/anon API key. The real privileges live only in the server-side service key.
  const apiKey = req.headers.get('apikey') ?? '';
  const acceptedKeys = [Deno.env.get('SUPABASE_ANON_KEY') ?? ''];
  try {
    const configured = JSON.parse(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS') ?? '{}') as Record<string, string>;
    acceptedKeys.push(...Object.values(configured));
  } catch (_) { /* optional on projects that expose only the legacy anon key */ }
  if (!apiKey || !acceptedKeys.filter(Boolean).includes(apiKey)) {
    return jsonResponse({ ok: false, error: 'تعذر التحقق من إعداد الاتصال.' }, 401, headers);
  }

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 65000) return jsonResponse({ ok: false, error: 'حجم البيانات أكبر من المسموح.' }, 413, headers);
    body = JSON.parse(raw);
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('invalid body');
  } catch (_) {
    return jsonResponse({ ok: false, error: 'بيانات الطلب غير صالحة.' }, 400, headers);
  }

  const action = body.action;
  if (!['create', 'track', 'update', 'cancel'].includes(String(action))) {
    return jsonResponse({ ok: false, error: 'العملية غير معروفة.' }, 400, headers);
  }
  try {
    const allowed = await rateLimit(req, action as 'create' | 'track' | 'update' | 'cancel');
    if (!allowed) return jsonResponse({ ok: false, error: 'محاولات كثيرة خلال وقت قصير. استنى 15 دقيقة وحاول تاني.' }, 429, headers);

    if (action === 'create') {
      const customerName = cleanText(body.p_customer_name, 100);
      const phone = normalizeDigits(cleanText(body.p_phone, 25));
      const address = cleanText(body.p_address, 500);
      const notes = cleanText(body.p_notes, 500);
      const items = body.p_items;
      const token = body.tracking_token;
      const idempotencyKey = body.idempotency_key;
      if (customerName.length < 2 || phone.length < 10 || phone.length > 15 || address.length < 5) {
        return jsonResponse({ ok: false, error: 'راجع الاسم ورقم الهاتف وعنوان التوصيل.' }, 400, headers);
      }
      if (!Array.isArray(items) || items.length < 1 || items.length > 30 || !isHexSecret(token) || !isHexSecret(idempotencyKey)) {
        return jsonResponse({ ok: false, error: 'بيانات الطلب أو مفاتيح الحماية غير صالحة. حدّث الصفحة وحاول مرة أخرى.' }, 400, headers);
      }
      if (!(await verifyTurnstile(body.captcha_token, req))) {
        return jsonResponse({ ok: false, error: 'فشل التحقق البشري. أعد التحقق وحاول مرة أخرى.' }, 403, headers);
      }
      const { data, error } = await admin.rpc('create_hopa_order_secure', {
        p_customer_name: customerName, p_phone: phone, p_address: address, p_notes: notes,
        p_items: items, p_tracking_token: token.toLowerCase(), p_idempotency_key: idempotencyKey.toLowerCase(),
      });
      if (error) {
        console.error('[Hopa create]', error.code, error.message);
        const message = error.code === '22023' ? error.message : 'تعذر تسجيل الطلب حاليًا. راجع البيانات أو حاول بعد قليل.';
        return jsonResponse({ ok: false, error: message }, error.code === '22023' ? 400 : 503, headers);
      }
      if (!data?.order_number) return jsonResponse({ ok: false, error: 'لم نستلم تأكيد الطلب من قاعدة البيانات.' }, 503, headers);
      const isReplay = data._idempotent_replay === true;
      const cleanOrder = { ...data } as Record<string, unknown>;
      delete cleanOrder._idempotent_replay;
      cleanOrder.tracking_token = token.toLowerCase();
      if (!isReplay) {
        try {
          EdgeRuntime.waitUntil(sendAdminEmail(cleanOrder).catch(() => {
            console.error('[Hopa notification] Non-blocking notification failed.');
          }));
        } catch (_) { /* Never fail order confirmation because email scheduling is unavailable. */ }
      }
      return jsonResponse({ ok: true, data: cleanOrder }, 200, headers);
    }

    const orderNumber = cleanText(body.order_number, 32).toUpperCase();
    const token = body.tracking_token;
    if (!/^HOPA-[0-9]{1,18}$/.test(orderNumber) || !isHexSecret(token)) {
      return jsonResponse({ ok: false, error: 'رقم الطلب أو رمز التتبع غير صحيح.' }, 400, headers);
    }
    if (action === 'track') {
      const { data, error } = await admin.rpc('get_hopa_order_by_token', {
        p_order_number: orderNumber, p_tracking_token: token.toLowerCase(),
      });
      if (error) throw error;
      if (!data) return jsonResponse({ ok: false, error: 'تعذر العثور على الطلب. راجع رقم الطلب ورمز التتبع.' }, 404, headers);
      data.tracking_token = token.toLowerCase();
      return jsonResponse({ ok: true, data }, 200, headers);
    }
    if (action === 'cancel') {
      const { data, error } = await admin.rpc('cancel_hopa_order_by_token', {
        p_order_number: orderNumber, p_tracking_token: token.toLowerCase(),
      });
      if (error) {
        const message = error.code === '22023' ? error.message : 'تعذر إلغاء الطلب. حاول مرة أخرى.';
        return jsonResponse({ ok: false, error: message }, error.code === '22023' ? 400 : 503, headers);
      }
      if (!data) return jsonResponse({ ok: false, error: 'تعذر إلغاء الطلب. راجع رابط التتبع.' }, 404, headers);
      data.tracking_token = token.toLowerCase();
      return jsonResponse({ ok: true, data }, 200, headers);
    }

    if (action === 'update') {
      const customerName = cleanText(body.p_customer_name, 100);
      const phone = normalizeDigits(cleanText(body.p_new_phone, 25));
      const address = cleanText(body.p_address, 500);
      const notes = cleanText(body.p_notes, 500);
      const items = body.p_items;
      if (customerName.length < 2 || phone.length < 10 || phone.length > 15 || address.length < 5 || !Array.isArray(items) || items.length < 1 || items.length > 30) {
        return jsonResponse({ ok: false, error: 'راجع بيانات العميل والأصناف والكميات.' }, 400, headers);
      }
      const { data, error } = await admin.rpc('update_hopa_order_by_token', {
        p_order_number: orderNumber, p_tracking_token: token.toLowerCase(),
        p_customer_name: customerName, p_new_phone: phone,
        p_address: address, p_notes: notes, p_items: items,
      });
      if (error) {
        const message = error.code === '22023' ? error.message : 'تعذر حفظ تعديلات الطلب. حاول مرة أخرى.';
        return jsonResponse({ ok: false, error: message }, error.code === '22023' ? 400 : 503, headers);
      }
      if (!data) return jsonResponse({ ok: false, error: 'تعذر تعديل الطلب. راجع رابط التتبع.' }, 404, headers);
      data.tracking_token = token.toLowerCase();
      return jsonResponse({ ok: true, data }, 200, headers);
    }
    return jsonResponse({ ok: false, error: 'العملية غير معروفة.' }, 400, headers);
  } catch (error) {
    console.error('[Hopa public API] Request failed:', error instanceof Error ? error.message : 'unknown error');
    return jsonResponse({ ok: false, error: 'حصل خطأ داخلي. جرّب مرة أخرى بعد قليل.' }, 500, headers);
  }
});
