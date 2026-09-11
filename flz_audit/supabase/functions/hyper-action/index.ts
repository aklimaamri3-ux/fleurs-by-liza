// ═══════════════════════════════════════════════════════
// Fleurs by Liza — Edge Function v4 (نسخة مُصلَّحة أمنيًا)
// Project: lgpllhbabctsdplqapzi
// Secrets: TG_TOKEN, TG_CHAT_ID, SLICKPAY_PUBLIC,
// SLICKPAY_SECRET, SLICKPAY_ENV, SLICKPAY_CONTACT,
// YALIDINE_TOKEN, YALIDINE_ID, RESEND_API_KEY
// جديد (اختياري): SLICKPAY_WEBHOOK_SECRET — توقيع HMAC للـ webhook
// جديد (اختياري): SITE_URL, EXTRA_ORIGINS — عدّليهم عبر
// `supabase secrets set SITE_URL=https://votredomaine.com` بعد نشر
// الموقع، بلا حاجة لإعادة نشر هذه الدالة.
//   EXTRA_ORIGINS يقبل عدة نطاقات مفصولة بفاصلة، مثال:
//   "https://votredomaine.com,https://www.votredomaine.com"
// ═══════════════════════════════════════════════════════

const SB_URL = Deno.env.get('SUPABASE_URL')!
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
// ✅ SITE_URL configurable via secret — falls back to the dev placeholder
// until the real domain is set (site is not deployed yet).
const SITE = Deno.env.get('SITE_URL') || 'https://maamri3-ux.github.io'

// ✅ CORS: قائمة بيضاء — القيمة الأساسية + أي نطاقات إضافية من EXTRA_ORIGINS
const ALLOWED_ORIGINS = new Set([
  'https://maamri3-ux.github.io',
  'http://localhost:5173',
  'http://localhost:3000',
  'http://localhost:8843', // local dev/test static server
  SITE,
  ...String(Deno.env.get('EXTRA_ORIGINS') || '').split(',').map(s => s.trim()).filter(Boolean),
])

// ✅ actions تحتاج admin JWT
const ADMIN_ACTIONS = new Set([
  'yalidine_wilayas', 'yalidine_rates', 'yalidine_communes',
  'yalidine_create_shipment', 'telegram_test', 'eur_rate', 'telegram_report',
  'get_receipt_url', 'get_admin_delivery_proof_url',
])

// ✅ Rate limiting لكل IP + action
const RATE_LIMIT: Record<string, { limit: number; windowMs: number }> = {
  telegram_notify:              { limit: 10,  windowMs: 60_000 },
  slickpay_create:              { limit: 20,  windowMs: 60_000 },
  slickpay_check:               { limit: 60,  windowMs: 60_000 },
  slickpay_webhook:             { limit: 120, windowMs: 60_000 },
  yalidine_create_shipment:     { limit: 30,  windowMs: 60_000 },
  send_email:                   { limit: 15,  windowMs: 60_000 },
  get_delivery_proof_url:       { limit: 20,  windowMs: 60_000 },
  get_receipt_url:              { limit: 60,  windowMs: 60_000 },
  get_admin_delivery_proof_url: { limit: 60,  windowMs: 60_000 },
}
const hits = new Map<string, { count: number; resetAt: number }>()

// ✅ أنماط معرّفات آمنة
const RE_NUM  = /^\d+$/
const RE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
// ✅ actual customer order ids (checkout.html): 'FBL' + Date.now(), e.g. FBL1788896221938
const RE_ORDER_ID = /^FBL\d{1,20}$/
const RE_EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

function idFilter(v: any): string | null {
  const s = String(v ?? '').trim()
  if (RE_NUM.test(s))      return 'id=eq.' + Number(s)
  if (RE_UUID.test(s))     return 'id=eq.' + s
  if (RE_ORDER_ID.test(s)) return 'id=eq.' + s
  return null
}

function num(v: any): number | null {
  const s = String(v ?? '').trim()
  return RE_NUM.test(s) ? Number(s) : null
}

// ✅ uploadImg() in admin.html stores the FULL public-style URL
// (".../storage/v1/object/public/<bucket>/<name>") even for private
// buckets, but a receipt uploaded by a customer may only ever have
// stored the bare object name. This normalizes either shape down to
// just "<bucket>/<name>" — what Storage's /object/sign/ endpoint
// actually expects — so signing works regardless of which upload
// path wrote the value.
function storagePath(urlOrName: string, bucket: string): string {
  const s = String(urlOrName || '').trim()
  if (!s) return ''
  const m = s.match(/\/storage\/v1\/object\/(?:public|sign|authenticated)?\/?([^?]+)/)
  if (m) return m[1].replace(/^\/+/, '')
  if (s.startsWith(bucket + '/')) return s
  return `${bucket}/${s.replace(/^\/+/, '')}`
}

Deno.serve(async (req) => {
  const h   = corsHeaders(req)
  const ok  = (data: any, status = 200) => new Response(JSON.stringify(data), { status, headers: { ...h, 'Content-Type': 'application/json' } })
  const err = (msg: string, status = 400) => new Response(JSON.stringify({ ok: false, error: msg }), { status, headers: { ...h, 'Content-Type': 'application/json' } })

  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: h })

  const url = new URL(req.url)

  let rawBody = ''
  try { rawBody = await req.text() } catch (_) {}
  let body: any = {}
  if (rawBody.trim()) { try { body = JSON.parse(rawBody) } catch (_) {} }

  // ✅ every existing frontend call sends `action` inside the JSON body, not
  // as a URL query param — accept both so nothing depends on which one a
  // caller happens to use.
  const action = url.searchParams.get('action') || String(body.action || '')

  // ✅ Rate limit
  const rl = RATE_LIMIT[action]
  if (rl && !allowHit(`${clientIp(req)}:${action}`, rl.limit, rl.windowMs)) {
    return err('Too many requests', 429)
  }

  // ✅ تحقق JWT للـ admin actions
  if (ADMIN_ACTIONS.has(action)) {
    try {
      const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
      if (!token) return err('Unauthorized', 401)
      const userRes = await jfetch(`${SB_URL}/auth/v1/user`, {
        headers: { apikey: SB_KEY, Authorization: `Bearer ${token}` }
      })
      if (!userRes.ok) return err('Invalid token', 401)
      const userData  = await userRes.json()
      const profFilter = idFilter(userData?.id ?? '')
      if (!profFilter) return err('Forbidden — admin only', 403)
      const profRes = await jfetch(`${SB_URL}/rest/v1/profiles?${profFilter}&select=role`, {
        headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` }
      })
      if (!profRes.ok) return err('Forbidden — admin only', 403)
      const profiles = await profRes.json()
      if (!profiles?.[0] || profiles[0].role !== 'admin') return err('Forbidden — admin only', 403)
    } catch (e) {
      console.error('Admin check error:', e)
      return err('Auth check failed', 500)
    }
  }

  try {

    // ── Health check ──
    if (!action || action === 'health') {
      return ok({ ok: true, service: 'Fleurs by Liza API v4' })
    }

    // ── Delivery proof: token-gated signed URL, server-side (service role) ──
    // customers never get direct storage access to the admin-only
    // delivery_proofs bucket — only a short-lived signed URL for their
    // own order, after the same receipt_token check every other
    // customer-facing order RPC uses.
    if (action === 'get_delivery_proof_url') {
      if (!(await featureEnabled('delivery_proof'))) return ok({ url: null })
      const filt = idFilter(body.order_id ?? '')
      if (!filt) return err('Invalid order_id', 400)
      const token = String(body.token ?? '').trim()
      if (!token) return err('Missing token', 400)
      const order = await getOrder(filt, 'receipt_token,delivery_proof_url,status')
      if (!order || order.receipt_token !== token) return err('Not found', 404)
      if (!order.delivery_proof_url) return ok({ url: null })
      const signRes = await jfetch(`${SB_URL}/storage/v1/object/sign/${storagePath(order.delivery_proof_url, 'delivery_proofs')}`, {
        method: 'POST',
        headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiresIn: 600 }),
      })
      if (!signRes.ok) return err('Failed to sign', 502)
      const signData = await signRes.json()
      const signed = signData?.signedURL || ''
      return ok({ url: signed ? `${SB_URL}/storage/v1${signed}` : null, status: order.status })
    }

    // ── Receipt image: admin-only signed URL, server-side (service role) ──
    // admin.html previously asked the visitor's own browser session to sign
    // storage URLs directly against Supabase Storage — fragile (depends on
    // the admin JWT's own storage permissions resolving correctly) and hard
    // to diagnose from outside the admin panel. This does the signing here,
    // with the service-role key, after verifying the caller is a real admin
    // (same JWT check as every other admin action) — matching the proven
    // get_delivery_proof_url pattern.
    if (action === 'get_receipt_url') {
      const filt = idFilter(body.order_id ?? '')
      if (!filt) return err('Invalid order_id', 400)
      const order = await getOrder(filt, 'receipt_url')
      if (!order) return err('Not found', 404)
      if (!order.receipt_url) return ok({ url: null })
      const signRes = await jfetch(`${SB_URL}/storage/v1/object/sign/${storagePath(order.receipt_url, 'receipts')}`, {
        method: 'POST',
        headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiresIn: 600 }),
      })
      if (!signRes.ok) return err('Failed to sign', 502)
      const signData = await signRes.json()
      const signed = signData?.signedURL || ''
      return ok({ url: signed ? `${SB_URL}/storage/v1${signed}` : null })
    }

    // ── Delivery proof image: admin-only signed URL (mirrors get_receipt_url
    // above) — used by the order-detail modal in admin.html, distinct from
    // the customer-facing, token-gated get_delivery_proof_url action ──
    if (action === 'get_admin_delivery_proof_url') {
      const filt = idFilter(body.order_id ?? '')
      if (!filt) return err('Invalid order_id', 400)
      const order = await getOrder(filt, 'delivery_proof_url')
      if (!order) return err('Not found', 404)
      if (!order.delivery_proof_url) return ok({ url: null })
      const signRes = await jfetch(`${SB_URL}/storage/v1/object/sign/${storagePath(order.delivery_proof_url, 'delivery_proofs')}`, {
        method: 'POST',
        headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiresIn: 600 }),
      })
      if (!signRes.ok) return err('Failed to sign', 502)
      const signData = await signRes.json()
      const signed = signData?.signedURL || ''
      return ok({ url: signed ? `${SB_URL}/storage/v1${signed}` : null })
    }

    // ── Daily report: pg_cron only, not an admin action ──
    // triggered by a scheduled Postgres job (pg_cron + pg_net), never by a
    // browser — authenticated with a dedicated CRON_SECRET (not the admin
    // JWT flow, not the service-role key) so a leak of this one value can
    // only ever trigger a report send, nothing else.
    if (action === 'cron_daily_report') {
      const cronSecret = Deno.env.get('CRON_SECRET')
      const provided = req.headers.get('X-Cron-Secret') || ''
      if (!cronSecret || provided !== cronSecret) return err('Unauthorized', 401)
      const from = new Date(Date.now() - 24 * 3600 * 1000).toISOString()
      const rows = await sbGet(`orders?created_at=gte.${from}&select=status,total,wilaya,product_name`)
      const list = (rows as any[]) || []
      if (!list.length) return ok({ ok: true, skipped: 'no orders' })
      const done = list.filter((o) => o.status !== 'cancelled')
      const rev = done.reduce((s, o) => s + (Number(o.total) || 0), 0)
      const wc: Record<string, number> = {}
      list.forEach((o) => { if (o.wilaya) wc[o.wilaya] = (wc[o.wilaya] || 0) + 1 })
      const topW = Object.entries(wc).sort((a, b) => b[1] - a[1])[0]
      const pc: Record<string, number> = {}
      list.forEach((o) => { const p = o.product_name || '?'; pc[p] = (pc[p] || 0) + 1 })
      const topP = Object.entries(pc).sort((a, b) => b[1] - a[1])[0]
      const dayAgo = new Date(Date.now() - 24 * 3600 * 1000).toISOString()
      const stale = ((await sbGet(`orders?payment_status=eq.waiting_review&created_at=lt.${dayAgo}&select=id`)) as any[]) || []
      const dateStr = new Date().toISOString().slice(0, 10)
      let msg = `📊 *تقرير ${dateStr}*\n\n📦 الطلبات: ${list.length}\n✅ الناجحة: ${done.length}\n💰 الإيرادات: ${rev.toLocaleString('fr-DZ')} دج\n`
      if (topW) msg += `🗺️ أكثر ولاية: ${topW[0]} (${topW[1]})\n`
      if (topP) msg += `🌹 أكثر منتج: ${topP[0]} (${topP[1]})\n`
      if (stale.length) msg += `\n⚠️ *طلبات تحتاج متابعة (بانتظار المراجعة +24 ساعة):* ${stale.length}\n`
      msg += '\n— Fleurs by Liza 🌹'
      return ok(await sendTG(msg))
    }

    // ── Telegram test ──
    if (action === 'telegram_test') {
      return ok(await sendTG('🌹 *Fleurs by Liza* — اختبار ناجح! ✅'))
    }

    // ── Telegram: تقرير/رسالة مخصصة من الأدمن (admin JWT مطلوب — محتوى موثوق) ──
    if (action === 'telegram_report') {
      const msg = String(body.message || '').trim().slice(0, 3900)
      if (!msg) return err('Missing message', 400)
      return ok(await sendTG(msg))
    }

    // ── Telegram: إشعار طلب ──
    if (action === 'telegram_notify') {
      if (!(await featureEnabled('telegram_notifications'))) return ok({ ok: true, skipped: true })
      const o = body.order
      if (!o) return err('no order', 400)
      const filt = idFilter(o.id ?? o.order_id ?? '')
      let exists = false
      if (filt) {
        const rows = await sbGet(`orders?${filt}&select=id`)
        exists = !!(rows as any[])[0]
      } else {
        const ref = sanitize(o.ref || '')
        if (ref) {
          try {
            const rows = await sbGet(`orders?ref=eq.${encodeURIComponent(ref)}&select=id`)
            exists = !!(rows as any[])[0]
          } catch (e) { console.error('ref lookup failed:', e) }
        }
      }
      if (!exists) return err('Order not found', 404)
      let msg = ''
      if (o._report && o.message) {
        msg = sanitize(o.message)
      } else {
        const ref = o.ref || o.id || '—'
        msg  = `🌹 *طلب جديد — Fleurs by Liza*\n━━━━━━━━━━━━━━\n`
        msg += `📋 *Réf:* #${sanitize(ref)}\n`
        msg += `👤 *الاسم:* ${sanitize(o.name)}\n`
        msg += `📞 *الهاتف:* ${sanitize(o.phone)}\n`
        msg += `🗺️ *الولاية:* ${sanitize(o.wilaya||'')}${o.commune?' — '+sanitize(o.commune):''}\n`
        msg += `🌹 *المنتج:* ${sanitize(o.product_name||o.product||'')} ×${Number(o.qty)||1}\n`
        msg += `💰 *المجموع:* ${Number(o.total)||0} دج\n`
        msg += `💳 *الدفع:* ${sanitize(o.payment_method||'')}\n`
        if (o.note) msg += `📝 *ملاحظة:* ${sanitize(o.note)}\n`
        if (o.source && o.source !== 'website') msg += `📲 *المصدر:* ${sanitize(o.source)}\n`
        msg += `━━━━━━━━━━━━━━`
      }
      return ok(await sendTG(msg.slice(0, 4000)))
    }

    // ── ✅ Resend: إرسال إيميل ──
    if (action === 'send_email') {
      if (!(await featureEnabled('email_notifications'))) return ok({ sent: false, reason: 'disabled' })
      const resendKey = Deno.env.get('RESEND_API_KEY')
      if (!resendKey) return ok({ sent: false, reason: 'not_configured' })

      const { type, order } = body
      if (!type || !order) return err('Missing type or order', 400)

      // ✅ تحقق من البريد
      const email = String(order.email || '').trim().toLowerCase()
      if (!email || !RE_EMAIL.test(email)) return ok({ sent: false, reason: 'no_email' })
      if (email.length > 254) return err('Invalid email', 400)

      const ref     = sanitize(order.ref || order.id || '—')
      const name    = sanitize(order.name || '')
      const product = sanitize(order.product_name || order.product || '')
      const total   = Number(order.total) || 0
      const wilaya  = sanitize(order.wilaya || '')
      const tracking = sanitize(order.yalidine_tracking || '')

      let subject = ''
      let html    = ''

      // ── Template: تأكيد الطلب ──
      if (type === 'order_confirm') {
        subject = `✅ تم استلام طلبك #${ref} — Fleurs by Liza`
        html = `<!DOCTYPE html><html dir="rtl" lang="ar">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font-family:Tajawal,Arial,sans-serif;background:#f8f7f5;margin:0;padding:20px}.wrap{max-width:500px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08)}.header{background:linear-gradient(135deg,#e91e8c,#8e24aa);padding:32px 24px;text-align:center}.logo{color:#fff;font-size:1.5rem;font-weight:700}.body{padding:28px 24px}.ref{background:#fce4f3;border-radius:8px;padding:12px 16px;text-align:center;margin-bottom:20px}.ref-num{font-size:1.2rem;font-weight:800;color:#e91e8c;font-family:monospace}.row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #f0f0f0;font-size:.88rem}.row:last-child{border:none}.label{color:#888}.val{font-weight:600}.total-row{background:#fce4f3;border-radius:8px;padding:12px 16px;display:flex;justify-content:space-between;margin-top:16px}.total-val{font-weight:800;font-size:1.1rem;color:#e91e8c;font-family:monospace}.footer{background:#f8f7f5;padding:20px 24px;text-align:center;font-size:.75rem;color:#888}.btn{display:inline-block;background:linear-gradient(135deg,#e91e8c,#8e24aa);color:#fff;text-decoration:none;padding:12px 28px;border-radius:24px;font-weight:700;margin:16px 0}</style>
</head><body><div class="wrap">
<div class="header"><div class="logo">Fleurs ❀ by liza</div><div style="color:rgba(255,255,255,.8);font-size:.82rem;margin-top:4px">FLOWER SHOP — ALGÉRIE</div></div>
<div class="body">
<p style="font-size:1rem;font-weight:600;margin-bottom:16px">مرحباً ${name} 🌹</p>
<p style="color:#555;font-size:.88rem;margin-bottom:20px">شكراً لطلبك! تم استلامه بنجاح وسنتواصل معك قريباً.</p>
<div class="ref"><div style="font-size:.75rem;color:#888;margin-bottom:4px">رقم طلبك</div><div class="ref-num">#${ref}</div></div>
<div class="row"><span class="label">المنتج</span><span class="val">${product}</span></div>
<div class="row"><span class="label">الولاية</span><span class="val">${wilaya}</span></div>
<div class="row"><span class="label">طريقة الدفع</span><span class="val">${sanitize(order.payment_method||'')}</span></div>
<div class="total-row"><span style="font-weight:700;color:#e91e8c">المجموع الكلي</span><span class="total-val">${total.toLocaleString('fr-DZ')} دج</span></div>
<div style="text-align:center;margin-top:24px"><a href="${SITE}/receipt.html?order=${encodeURIComponent(order.id||'')}" class="btn">📋 تتبع طلبك</a></div>
</div>
<div class="footer">Fleurs by Liza — شكراً لثقتك بنا 🌹</div>
</div></body></html>`
      }

      // ── Template: الطلب في الطريق ──
      else if (type === 'order_shipping') {
        subject = `🚚 طلبك #${ref} في الطريق إليك! — Fleurs by Liza`
        html = `<!DOCTYPE html><html dir="rtl" lang="ar">
<head><meta charset="UTF-8"><style>body{font-family:Tajawal,Arial,sans-serif;background:#f8f7f5;margin:0;padding:20px}.wrap{max-width:500px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08)}.header{background:linear-gradient(135deg,#27ae60,#2ecc71);padding:32px 24px;text-align:center;color:#fff}.body{padding:28px 24px}.track{background:#f0fff4;border:2px solid #27ae60;border-radius:8px;padding:16px;text-align:center;margin:16px 0}.footer{background:#f8f7f5;padding:20px;text-align:center;font-size:.75rem;color:#888}.btn{display:inline-block;background:#27ae60;color:#fff;text-decoration:none;padding:12px 28px;border-radius:24px;font-weight:700;margin:16px 0}</style></head>
<body><div class="wrap">
<div class="header"><div style="font-size:2rem">🚚</div><div style="font-size:1.1rem;font-weight:700;margin-top:8px">طلبك في الطريق!</div><div style="opacity:.85;font-size:.82rem">Fleurs ❀ by liza</div></div>
<div class="body">
<p>مرحباً ${name} 🌹</p>
<p style="color:#555;font-size:.88rem">طلبك رقم <strong>#${ref}</strong> خرج للتوصيل. يرجى التواجد لاستلامه.</p>
${tracking ? `<div class="track"><div style="font-size:.75rem;color:#888">رقم التتبع (Yalidine)</div><div style="font-size:1.1rem;font-weight:800;font-family:monospace;color:#27ae60">${tracking}</div></div>` : ''}
<div style="text-align:center"><a href="${SITE}/receipt.html?order=${encodeURIComponent(order.id||'')}" class="btn">📦 تتبع طلبك</a></div>
</div>
<div class="footer">Fleurs by Liza 🌹</div>
</div></body></html>`
      }

      // ── Template: تم التوصيل ──
      else if (type === 'order_delivered') {
        subject = `📦 تم توصيل طلبك #${ref} — Fleurs by Liza 🌹`
        html = `<!DOCTYPE html><html dir="rtl" lang="ar">
<head><meta charset="UTF-8"><style>body{font-family:Tajawal,Arial,sans-serif;background:#f8f7f5;margin:0;padding:20px}.wrap{max-width:500px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08)}.header{background:linear-gradient(135deg,#c8963c,#e91e8c);padding:32px 24px;text-align:center;color:#fff}.body{padding:28px 24px;text-align:center}.footer{background:#f8f7f5;padding:20px;text-align:center;font-size:.75rem;color:#888}.btn{display:inline-block;background:linear-gradient(135deg,#e91e8c,#8e24aa);color:#fff;text-decoration:none;padding:12px 28px;border-radius:24px;font-weight:700;margin:16px 0}</style></head>
<body><div class="wrap">
<div class="header"><div style="font-size:2.5rem">🌹</div><div style="font-size:1.1rem;font-weight:700;margin-top:8px">تم التوصيل بنجاح!</div><div style="opacity:.85;font-size:.82rem">Fleurs ❀ by liza</div></div>
<div class="body">
<p style="font-size:1rem;font-weight:600">شكراً ${name}! 🌹</p>
<p style="color:#555;font-size:.88rem">نتمنى أن يعجبك طلبك رقم <strong>#${ref}</strong></p>
<a href="https://instagram.com/fleurs_byliza" class="btn">⭐ شاركي رأيك</a>
</div>
<div class="footer">Fleurs by Liza — نراك في طلبك القادم 🌹</div>
</div></body></html>`
      }

      // ── Template: الطلب أُلغي ──
      else if (type === 'order_cancelled') {
        subject = `❌ طلبك #${ref} أُلغي — Fleurs by Liza`
        html = `<!DOCTYPE html><html dir="rtl" lang="ar">
<head><meta charset="UTF-8"><style>body{font-family:Tajawal,Arial,sans-serif;background:#f8f7f5;margin:0;padding:20px}.wrap{max-width:500px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08)}.header{background:linear-gradient(135deg,#7f8c8d,#95a5a6);padding:32px 24px;text-align:center;color:#fff}.body{padding:28px 24px}.footer{background:#f8f7f5;padding:20px;text-align:center;font-size:.75rem;color:#888}</style></head>
<body><div class="wrap">
<div class="header"><div style="font-size:2rem">❌</div><div style="font-size:1.1rem;font-weight:700;margin-top:8px">تم إلغاء الطلب</div><div style="opacity:.85;font-size:.82rem">Fleurs ❀ by liza</div></div>
<div class="body">
<p>مرحباً ${name}</p>
<p style="color:#555;font-size:.88rem">نعتذر، تم إلغاء طلبك رقم <strong>#${ref}</strong>. للاستفسار تواصلي معنا.</p>
</div>
<div class="footer">Fleurs by Liza 🌹</div>
</div></body></html>`
      }

      else { return err('Unknown email type: ' + sanitize(type), 400) }

      // ── إرسال عبر Resend ──
      const res = await jfetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: 'Fleurs by Liza <noreply@resend.dev>',
          to:   [email],
          subject,
          html,
        }),
      })
      const data = await res.json()
      if (!res.ok) {
        console.error('Resend error:', data)
        return err('Email failed: ' + (data?.message || res.status), 502)
      }
      return ok({ sent: true, id: data.id })
    }

    // ── SlickPay: إنشاء فاتورة ──
    // API docs (developers.slick-pay.com): single Bearer key, prod base is
    // prodapi.slick-pay.com (not api.slick-pay.com), invoice id/url are
    // top-level fields in the create response, and invoice status comes
    // back as a top-level `completed` (0/1) field — not `data.payment_status`.
    if (action === 'slickpay_create') {
      const key = slickpayKey()
      if (!key) return err('SlickPay not configured', 500)
      const base     = slickpayBase()
      const filt     = idFilter(body.order_id ?? '')
      if (!filt) return err('Invalid order_id', 400)
      const order    = await getOrder(filt, 'total,payment_status,slickpay_order_id,name,phone,email,address,wilaya,commune,receipt_token')
      if (!order) return err('Order not found', 404)
      const uid = await requireUser(req)
      if (order.user_id && uid !== order.user_id && !(await isAdmin(uid))) return err('Forbidden', 403)
      if (order.payment_status === 'paid')    return err('Order already paid', 409)
      if (order.slickpay_order_id)            return err('Invoice already created', 409)
      const amount = Number(order.total) || 0
      if (!(amount > 0) || amount > 10_000_000) return err('Invalid order total', 400)

      const envContact = Deno.env.get('SLICKPAY_CONTACT') || ''
      const nameParts   = sanitize(order.name || 'Client').split(' ')
      const invoicePayload: Record<string, unknown> = {
        amount,
        url: `${SITE}/receipt.html?order=${order.id}&paid=1&token=${order.receipt_token || ''}`,
        webhook_url: `${SB_URL}/functions/v1/hyper-action?action=slickpay_webhook`,
        items: [{ name: `Commande #${order.id}`, price: amount, quantity: 1 }],
        note: `Fleurs by Liza — commande #${order.id}`,
      }
      if (envContact) {
        invoicePayload.contact = envContact
      } else {
        invoicePayload.firstname = nameParts[0] || 'Client'
        invoicePayload.lastname  = nameParts.slice(1).join(' ') || '.'
        invoicePayload.phone     = sanitize(order.phone || '')
        if (order.email) invoicePayload.email = sanitize(order.email)
        const addr = [order.address, order.commune, order.wilaya].filter(Boolean).join(', ')
        invoicePayload.address = sanitize(addr || order.wilaya || 'Algérie')
      }
      const whSecret = Deno.env.get('SLICKPAY_WEBHOOK_SECRET')
      if (whSecret) invoicePayload.webhook_signature = whSecret

      const res = await jfetch(`${base}/users/invoices`, {
        method: 'POST',
        headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': `Bearer ${key}` },
        body: JSON.stringify(invoicePayload),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data?.success) {
        console.error('SlickPay create failed:', res.status, data)
        return err('SlickPay: ' + (data?.message || res.status), 502)
      }
      const payUrl    = data?.url || data?.data?.url || data?.data?.payment_url || ''
      const invoiceId = data?.id  ?? data?.data?.id   ?? data?.data?.invoice_number ?? ''
      if (!payUrl || invoiceId === '') { console.error('SlickPay create: missing url/id in response', data); return err('SlickPay: unexpected response', 502) }
      try { await sbPatch('orders', filt, { slickpay_order_id: String(invoiceId), payment_status: 'waiting_slickpay' }) }
      catch (e) { console.error('Failed to save invoice id:', e); return err('Failed to save invoice', 500) }
      return ok({ success: true, payment_url: payUrl, invoice_id: invoiceId })
    }

    // ── SlickPay: فحص الحالة (server-authoritative — used by receipt.html polling) ──
    if (action === 'slickpay_check') {
      const key  = slickpayKey()
      if (!key) return err('SlickPay not configured', 500)
      const filt = idFilter(body.order_id ?? '')
      if (!filt) return err('Invalid order_id', 400)
      const order = await getOrder(filt, 'slickpay_order_id,payment_status,total')
      if (!order) return err('Order not found', 404)
      const uid = await requireUser(req)
      if (order.user_id && uid !== order.user_id && !(await isAdmin(uid))) return err('Forbidden', 403)
      if (!order.slickpay_order_id) return ok({ payment_status: order.payment_status || 'pending' })
      // ✅ already confirmed paid previously — no need to re-verify or re-trust anything new
      if (order.payment_status === 'paid') return ok({ payment_status: 'paid' })
      const base = slickpayBase()
      const res  = await jfetch(`${base}/users/invoices/${encodeURIComponent(String(order.slickpay_order_id))}`, {
        headers: { 'Accept': 'application/json', 'Authorization': `Bearer ${key}` },
      })
      if (res.ok) {
        const d      = await res.json()
        const isPaid = d?.completed === 1 || d?.completed === true || (d?.data?.payment_status === 'paid')
        if (isPaid) {
          // ✅ same amount-mismatch guard as the webhook — see comment there.
          // SlickPay's own invoice schema for the paid amount is undocumented,
          // so this is defense-in-depth on top of (not a replacement for) the
          // primary safeguard: `completed` can only be true for THIS exact
          // invoice id, which we created ourselves with a fixed amount, and
          // that field can only come from SlickPay's real backend.
          const inv = (typeof d?.data === 'string') ? (() => { try { return JSON.parse(d.data) } catch { return {} } })() : (d?.data || {})
          const paidAmount  = Number(inv?.amount ?? inv?.price ?? 0)
          const orderAmount = Number(order?.total ?? 0)
          if (paidAmount > 0 && orderAmount > 0 && Math.abs(paidAmount - orderAmount) > 1) {
            console.error(`slickpay_check amount mismatch: order=${filt} paid=${paidAmount} total=${orderAmount}`)
            return ok({ payment_status: 'pending' })
          }
          try { await sbPatch('orders', filt, { payment_status: 'paid', status: 'confirmed' }) }
          catch (e) { console.error('Check patch failed:', e) }
          return ok({ payment_status: 'paid' })
        }
        return ok({ payment_status: 'pending' })
      }
      return ok({ payment_status: order.payment_status || 'pending' })
    }

    // ── SlickPay Webhook ──
    // Deployed with verify_jwt=false for this function (see config.toml) —
    // SlickPay's server has no way to send a Supabase JWT. Security instead
    // comes from: (1) an optional HMAC check if SLICKPAY_WEBHOOK_SECRET is
    // set, and (2) always re-fetching the invoice from SlickPay's API with
    // our own trusted key before trusting anything the webhook body claims —
    // a forged call can only reference an invoice id that already matches
    // one of OUR orders (attacker-uncontrollable) and still can't fake the
    // authoritative `completed` status, since that's re-checked server-side.
    if (action === 'slickpay_webhook') {
      const whSecret = Deno.env.get('SLICKPAY_WEBHOOK_SECRET')
      if (whSecret) {
        const sig = req.headers.get('x-slickpay-signature') || req.headers.get('x-signature') || ''
        if (sig && !(await verifyHmac(whSecret, rawBody, sig))) return err('Invalid signature', 401)
      }
      const invoiceNum = String(
        body?.id ?? body?.data?.id ?? body?.invoice_number ?? body?.data?.invoice_number ?? ''
      ).trim()
      if (!invoiceNum) return ok({ received: true })
      const enc = encodeURIComponent(invoiceNum)
      let order: any = null
      try {
        const rows = await sbGet(`orders?slickpay_order_id=eq.${enc}&select=id,payment_status,total`)
        order = (rows as any[])[0] || null
      } catch (e) {
        console.warn('total column missing?', e)
        const rows = await sbGet(`orders?slickpay_order_id=eq.${enc}&select=id,payment_status`)
        order = (rows as any[])[0] || null
      }
      if (!order) return ok({ received: true })
      const key = slickpayKey()
      if (!key) return err('SlickPay not configured', 500)
      const base = slickpayBase()
      const ver  = await jfetch(`${base}/users/invoices/${enc}`, {
        headers: { 'Accept': 'application/json', 'Authorization': `Bearer ${key}` },
      })
      if (!ver.ok) return err('Verification failed', 502)
      const d           = await ver.json()
      const reallyPaid  = d?.completed === 1 || d?.completed === true || (d?.data?.payment_status === 'paid')
      if (!reallyPaid)  return ok({ received: true, status: 'pending' })
      const inv = (typeof d?.data === 'string') ? (() => { try { return JSON.parse(d.data) } catch { return {} } })() : (d?.data || {})
      const paidAmount  = Number(inv?.amount ?? inv?.price ?? 0)
      const orderAmount = Number(order?.total ?? 0)
      if (paidAmount > 0 && orderAmount > 0 && Math.abs(paidAmount - orderAmount) > 1) {
        console.error(`Amount mismatch: invoice=${invoiceNum} paid=${paidAmount} order=${order.id} total=${orderAmount}`)
        return ok({ received: true, confirmed: false })
      }
      if (order.payment_status !== 'paid') {
        const ofilt = idFilter(order.id)
        if (ofilt) {
          try { await sbPatch('orders', ofilt, { payment_status: 'paid', status: 'confirmed' }) }
          catch (e) { console.error('Webhook DB patch failed:', e) }
        }
      }
      return ok({ received: true, confirmed: true })
    }

    // ── Yalidine: ولايات + بلديات + أسعار ──
    if (action === 'yalidine_wilayas' || action === 'yalidine_rates') {
      const token = Deno.env.get('YALIDINE_TOKEN')
      const id    = Deno.env.get('YALIDINE_ID')
      if (!token || !id) return err('Yalidine not configured', 500)
      const wRes  = await jfetch('https://api.yalidine.app/v1/wilayas/?page_size=58', { headers: { 'X-API-ID': id, 'X-API-TOKEN': token } })
      if (!wRes.ok) return err('Yalidine wilayas: ' + wRes.status, 502)
      const wData   = await wRes.json()
      const wilayas = wData.data || []
      const cRes    = await jfetch('https://api.yalidine.app/v1/communes/?page_size=1000', { headers: { 'X-API-ID': id, 'X-API-TOKEN': token } })
      const cData   = cRes.ok ? await cRes.json() : { data: [] }
      const communes = cData.data || []
      const rates = wilayas.map((w: any) => ({
        wilaya_id: w.id, wilaya_name: w.name, home_price: w.home_price || 0, office_price: w.desk_price || 0,
        communes: communes.filter((c: any) => c.wilaya_id === w.id).map((c: any) => ({
          id: c.id, name: c.name,
          home_price:   c.has_home_delivery ? (w.home_price || 0) : null,
          office_price: w.desk_price || 0,
        })),
      }))
      return ok({ success: true, rates, total: rates.length })
    }

    // ── Yalidine: بلديات ولاية ──
    if (action === 'yalidine_communes') {
      const token    = Deno.env.get('YALIDINE_TOKEN')
      const id       = Deno.env.get('YALIDINE_ID')
      const wilayaId = num(body.wilaya_id ?? url.searchParams.get('wilaya_id'))
      if (!token || !id) return err('Yalidine not configured', 500)
      if (!wilayaId)     return err('Invalid wilaya_id', 400)
      const res  = await jfetch(`https://api.yalidine.app/v1/communes/?wilaya_id=${wilayaId}&page_size=100`, { headers: { 'X-API-ID': id, 'X-API-TOKEN': token } })
      if (!res.ok) return err('Yalidine communes: ' + res.status, 502)
      const data = await res.json()
      return ok({ success: true, data: data.data })
    }

    // ── Yalidine: إنشاء شحنة (admin) ──
    if (action === 'yalidine_create_shipment') {
      if (!(await featureEnabled('yalidine'))) return err('Yalidine is currently disabled', 403)
      const token = Deno.env.get('YALIDINE_TOKEN')
      const id    = Deno.env.get('YALIDINE_ID')
      if (!token || !id) return err('Yalidine not configured', 500)
      const o = body.order
      if (!o)        return err('Missing order', 400)
      if (!o.phone)  return err('Missing phone', 400)
      const wilayaId = num(o.wilaya_id)
      if (!wilayaId) return err('Missing/invalid wilaya_id', 400)
      const phone     = String(o.phone).replace(/\D/g, '')
      const nameParts = sanitize(o.name || 'Client').split(' ')
      // ✅ عندنا اسم البلدية نصياً فقط (من نظامنا)، لا معرّف Yalidine
      // الرقمي — نطابقه مع قائمة بلديات Yalidine الحقيقية لنفس الولاية
      // حتى تصل الشحنة بمعلومات ولاية/بلدية صحيحة ودقيقة، لا الولاية فقط
      let toCommuneId: number | undefined = o.commune_id ? (num(o.commune_id) ?? undefined) : undefined
      if (!toCommuneId && o.commune) {
        try {
          const cRes = await jfetch(`https://api.yalidine.app/v1/communes/?wilaya_id=${wilayaId}&page_size=100`, { headers: { 'X-API-ID': id, 'X-API-TOKEN': token } })
          if (cRes.ok) {
            const cData = await cRes.json()
            const wanted = String(o.commune).trim().toLowerCase()
            const match = (cData.data || []).find((c: any) => String(c.name || '').trim().toLowerCase() === wanted)
            if (match) toCommuneId = match.id
          }
        } catch (e) { console.error('yalidine commune lookup failed:', e) }
      }
      const payload   = {
        firstname:      nameParts[0] || 'Client',
        familyname:     nameParts.slice(1).join(' ') || '.',
        contact_phone:  phone,
        address:        sanitize(o.address || o.commune || o.wilaya || '').slice(0, 100),
        to_wilaya_id:   wilayaId,
        to_commune_id:  toCommuneId,
        product_list:   sanitize(o.product_name || 'Bouquet').slice(0, 100),
        price:          Number(o.total) || 0,
        do_insurance:   false, declared_value: Number(o.total) || 0,
        height: 10, width: 20, length: 20, weight: 0.5,
        freeshipping:   Number(o.delivery_cost) === 0,
        is_stopdesk:    !!o.is_stopdesk, has_exchange: false,
        reference:      sanitize(o.ref || o.id || '').slice(0, 50),
        note:           sanitize(o.note || '').slice(0, 200),
      }
      const res  = await jfetch('https://api.yalidine.app/v1/parcels/', {
        method: 'POST', headers: { 'X-API-ID': id, 'X-API-TOKEN': token, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      const data        = await res.json()
      if (!res.ok) return err('Yalidine: ' + (data?.message || data?.detail || res.status), 502)
      const tracking    = data?.barcode || data?.tracking_code || data?.data?.barcode || ''
      const shipmentId  = data?.id      || data?.data?.id      || ''
      if (o.id && (tracking || shipmentId)) {
        const filt = idFilter(o.id)
        if (filt) {
          try { await sbPatch('orders', filt, { status: 'shipping', yalidine_tracking: tracking, yalidine_shipment_id: String(shipmentId) }) }
          catch (e) { console.error('Failed to save shipment ref:', e) }
        }
      }
      return ok({ success: true, tracking, shipment_id: shipmentId })
    }

    // ── سعر اليورو ──
    if (action === 'eur_rate') {
      try {
        const res  = await jfetch('https://api.exchangerate-api.com/v4/latest/EUR')
        const data = await res.json()
        return ok({ eur_to_dzd: Math.round(data.rates?.DZD || 270) })
      } catch (_) { return ok({ eur_to_dzd: 270 }) }
    }

    return err('Unknown action: ' + action, 400)

  } catch (e: any) {
    console.error('Edge error:', e)
    return err('Internal error', 500)
  }
})

// ══════════════════════ HELPERS ══════════════════════

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get('origin') || ''
  const h: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  }
  if (ALLOWED_ORIGINS.has(origin)) { h['Access-Control-Allow-Origin'] = origin; h['Vary'] = 'Origin' }
  return h
}

function clientIp(req: Request): string {
  const fwd = req.headers.get('x-forwarded-for') || ''
  const ip  = fwd.split(',')[0]?.trim()
  return ip && ip.length < 64 ? ip : 'unknown'
}

function allowHit(key: string, limit: number, windowMs: number): boolean {
  const now = Date.now()
  if (hits.size > 2000) { for (const [k, v] of hits) if (v.resetAt <= now) hits.delete(k) }
  const rec = hits.get(key)
  if (!rec || rec.resetAt <= now) { hits.set(key, { count: 1, resetAt: now + windowMs }); return true }
  rec.count++
  return rec.count <= limit
}

// ✅ SlickPay's own docs describe a single Bearer API key, issued in the
// `<id>|<token>` shape and called PUBLIC_KEY in their dashboard — that is
// the value actually accepted as `Authorization: Bearer …` for every API
// call. SLICKPAY_SECRET is kept as a fallback in case that naming differs
// per account, but SLICKPAY_PUBLIC is the documented, correct credential.
function slickpayKey(): string {
  return Deno.env.get('SLICKPAY_PUBLIC') || Deno.env.get('SLICKPAY_SECRET') || ''
}

function slickpayBase(): string {
  const isProd = Deno.env.get('SLICKPAY_ENV') === 'prod' || Deno.env.get('SLICKPAY_ENV') === 'live'
  return (isProd ? 'https://prodapi.slick-pay.com' : 'https://devapi.slick-pay.com') + '/api/v2'
}

// ✅ real, server-side feature flag check — not just UI hiding. Fails
// open (returns true) on any error so a settings hiccup never takes
// the whole site down; the actual on/off switch lives in
// settings.feature_flags, admin-only to write.
async function featureEnabled(key: string): Promise<boolean> {
  try {
    const r = await jfetch(`${SB_URL}/rest/v1/rpc/is_feature_enabled`, {
      method: 'POST',
      headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_key: key }),
    }, 5_000)
    if (!r.ok) return true
    return (await r.json()) !== false
  } catch { return true }
}

async function jfetch(url: string, init: RequestInit = {}, ms = 10_000): Promise<Response> {
  const ctrl = new AbortController()
  const t    = setTimeout(() => ctrl.abort(), ms)
  try { return await fetch(url, { ...init, signal: ctrl.signal }) } finally { clearTimeout(t) }
}

async function verifyHmac(secret: string, payload: string, signature: string): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
    const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload))
    const hex = [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, '0')).join('')
    const a   = new TextEncoder().encode(hex)
    const b   = new TextEncoder().encode(signature.toLowerCase())
    if (a.length !== b.length) return false
    let diff  = 0
    for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
    return diff === 0
  } catch { return false }
}

async function requireUser(req: Request): Promise<string | null> {
  const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '').trim()
  if (!token) return null
  try {
    const res = await jfetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: SB_KEY, Authorization: `Bearer ${token}` } })
    if (!res.ok) return null
    const data = await res.json()
    return typeof data?.id === 'string' ? data.id : null
  } catch { return null }
}

async function isAdmin(userId: string | null): Promise<boolean> {
  if (!userId || !RE_UUID.test(userId)) return false
  try {
    const res = await jfetch(`${SB_URL}/rest/v1/profiles?id=eq.${userId}&select=role`, { headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` } })
    if (!res.ok) return false
    const p = await res.json()
    return !!p?.[0] && p[0].role === 'admin'
  } catch { return false }
}

async function getOrder(filt: string, extra: string): Promise<any | null> {
  try {
    const rows = await sbGet(`orders?${filt}&select=id,user_id,${extra}`)
    return (rows as any[])[0] || null
  } catch (e) {
    console.warn('user_id column missing — treating as public order:', e)
    const rows = await sbGet(`orders?${filt}&select=id,${extra}`)
    const o    = (rows as any[])[0]
    if (o) o.user_id = null
    return o || null
  }
}

function sanitize(s: any): string {
  return String(s || '').replace(/[*_`\[\]<>]/g, '').slice(0, 200)
}

async function sendTG(text: string) {
  const token  = Deno.env.get('TG_TOKEN')
  const chatId = Deno.env.get('TG_CHAT_ID')
  if (!token || !chatId) return { ok: false, error: 'TG not configured' }
  try {
    const r = await jfetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'Markdown' }),
    }, 8_000)
    const d = await r.json()
    return { ok: d.ok, error: d.description }
  } catch (e: any) { return { ok: false, error: String(e) } }
}

async function sbGet(path: string) {
  const r = await jfetch(`${SB_URL}/rest/v1/${path}`, { headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` } })
  if (!r.ok) throw new Error(`DB GET ${r.status}`)
  return r.json()
}

async function sbPatch(table: string, filter: string, data: object) {
  const r = await jfetch(`${SB_URL}/rest/v1/${table}?${filter}`, {
    method: 'PATCH',
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify(data),
  })
  if (!r.ok) throw new Error(`DB PATCH ${r.status}`)
  return r
}