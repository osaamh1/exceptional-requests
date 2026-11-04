// =====================================================================
//  تنبيهات تلقرام — بوابة الطلبات الاستثنائية · كلية الشريعة
//  - طلب جديد            (يُستدعى من قاعدة البيانات عند إنشاء الطلب)
//  - استكمل الطالب طلبه   (عند إرسال الطالب للاستكمال)
//  - ملخص المتأخرات       (الأحد–الخميس 8:00 و 11:45 بتوقيت الرياض)
//  - تسجيل المستلمين عبر رابط الانضمام الخاص بالبوت (/start <code>)
//  التوكن محفوظ كسرّ TELEGRAM_BOT_TOKEN ولا يظهر في الكود.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN") ?? "";
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const ADMIN_URL = "https://osaamh1.github.io/exceptional-requests/admin.html";
const LATE_DAYS = 2;
const FRESH_MS = 15 * 60 * 1000;   // only alert about events from the last 15 minutes

const CATEGORY: Record<string, string> = { registration: "تسجيل المقررات", exams: "الاختبارات", postpone: "اعتذار وتأجيل", plan: "الخطة والمعادلة", other: "أخرى" };
const STATUS: Record<string, string> = { new: "جديد", in_review: "قيد المراجعة", needs_info: "بانتظار استكمال الطالب", at_dean: "لدى العميد" };
const GENDER: Record<string, string> = { male: "طالب", female: "طالبة" };
const LEVEL: Record<string, string> = { bachelor: "بكالوريوس", master: "ماجستير", phd: "دكتوراه" };

const esc = (s: unknown) => String(s ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

async function tg(method: string, body: Record<string, unknown>) {
  const r = await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
  });
  return await r.json();
}
async function webhookSecret() {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("exreq:" + TOKEN));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 48);
}
async function recipients(): Promise<number[]> {
  const { data } = await sb.from("notify_recipients").select("chat_id").eq("active", true);
  return (data ?? []).map((r) => r.chat_id);
}
async function broadcast(text: string, withButton = true) {
  const ids = await recipients();
  const markup = withButton ? { inline_keyboard: [[{ text: "فتح لوحة الطلبات", url: ADMIN_URL }]] } : undefined;
  await Promise.all(ids.map((chat_id) =>
    tg("sendMessage", { chat_id, text, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: markup })));
  return ids.length;
}
const fresh = (iso?: string | null) => !!iso && Date.now() - new Date(iso).getTime() < FRESH_MS;

function card(r: Record<string, any>) {
  return [
    `رقم الطلب: <b>${esc(r.ref_no)}</b>`,
    `مقدّم الطلب: ${esc(r.student_name)} (${GENDER[r.gender] ?? ""} · ${LEVEL[r.level] ?? ""})`,
    `القسم: ${esc(r.department)}${r.college ? ` — ${esc(r.college)}` : ""}`,
    `النوع: ${CATEGORY[r.category] ?? ""}`,
    `المطلوب: ${esc(r.summary)}`,
  ].join("\n");
}

async function onNew(id: string) {
  const { data: r } = await sb.from("requests").select("*").eq("id", id).maybeSingle();
  if (!r || r.notified_new_at || !fresh(r.created_at)) return { skipped: true };
  await sb.from("requests").update({ notified_new_at: new Date().toISOString() }).eq("id", id);
  const sent = await broadcast(`🆕 <b>طلب استثنائي جديد</b>\n\n${card(r)}`);
  return { sent };
}

async function onCompleted(id: string) {
  const { data: r } = await sb.from("requests").select("*").eq("id", id).maybeSingle();
  if (!r || !fresh(r.student_replied_at)) return { skipped: true };
  if (r.notified_reply_at && new Date(r.notified_reply_at) >= new Date(r.student_replied_at)) return { skipped: true };
  await sb.from("requests").update({ notified_reply_at: new Date().toISOString() }).eq("id", id);
  const { data: ev } = await sb.from("request_events").select("note").eq("request_id", id).eq("action", "completed")
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  const { count } = await sb.from("request_files").select("id", { count: "exact", head: true }).eq("request_id", id).eq("stage", "completion");
  const sent = await broadcast(`↩️ <b>استكمل الطالب طلبه</b>\n\n${card(r)}` +
    (ev?.note ? `\n\nردّ الطالب: ${esc(ev.note)}` : "") + (count ? `\nمرفقات الاستكمال: ${count}` : ""));
  return { sent };
}

async function onDigest() {
  const { data: st } = await sb.from("settings").select("last_digest_at").eq("id", 1).maybeSingle();
  if (st?.last_digest_at && Date.now() - new Date(st.last_digest_at).getTime() < 2 * 3600 * 1000) return { skipped: true };
  await sb.from("settings").update({ last_digest_at: new Date().toISOString() }).eq("id", 1);
  const cutoff = new Date(Date.now() - LATE_DAYS * 86400000).toISOString();
  const { data: late } = await sb.from("requests").select("ref_no,student_name,status,updated_at")
    .in("status", ["new", "in_review", "needs_info", "at_dean"]).lt("updated_at", cutoff).order("updated_at");
  if (!late?.length) return { late: 0 };
  const lines = late.map((r) => {
    const d = Math.floor((Date.now() - new Date(r.updated_at).getTime()) / 86400000);
    return `• <b>${esc(r.ref_no)}</b> — ${esc(r.student_name)}\n   ${STATUS[r.status] ?? r.status} · بلا حركة منذ ${d} ${d >= 3 && d <= 10 ? "أيام" : "يوماً"}`;
  });
  const sent = await broadcast(`⏰ <b>طلبات متأخرة (${late.length})</b>\n\n${lines.join("\n")}`);
  return { late: late.length, sent };
}

// ---------- معاملات إنجاز: لأصحاب صلاحية المعاملات فقط (notify_recipients.enjaz) ----------
async function onEnjaz(id: string) {
  const { data: t } = await sb.from("enjaz_items").select("*").eq("id", id).maybeSingle();
  if (!t || t.notified_at || !fresh(t.directed_at)) return { skipped: true };
  await sb.from("enjaz_items").update({ notified_at: new Date().toISOString() }).eq("id", id);
  const { data: rs } = await sb.from("notify_recipients").select("chat_id").eq("active", true).eq("enjaz", true);
  const ids = (rs ?? []).map((r) => r.chat_id);
  const { data: voice } = await sb.from("enjaz_files").select("path,mime,duration_s").eq("item_id", id).eq("kind", "voice")
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  const head = t.status === "discuss" ? "💬 <b>معاملة يرغب سعادة العميد مناقشتها</b>" : "✅ <b>وجّه سعادة العميد على معاملة</b>";
  const text = [head, "", `<b>${esc(t.title)}</b>`, `رقم إنجاز: ${esc(t.enjaz_no)}${t.source ? ` · ${esc(t.source)}` : ""}`,
    t.dean_text ? `\nالتوجيه: ${esc(t.dean_text)}` : "", voice ? "\n🎙 مع تسجيل صوتي (مرفق أدناه)" : ""].filter((x) => x !== "").join("\n");
  const markup = { inline_keyboard: [[{ text: "فتح معاملات إنجاز", url: ADMIN_URL + "#enjaz" }]] };
  let blob: Blob | null = null;
  if (voice) {
    const { data } = await sb.storage.from("enjaz-files").download(voice.path);
    blob = data ?? null;
  }
  for (const chat_id of ids) {
    await tg("sendMessage", { chat_id, text, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: markup });
    if (blob) {
      try {
        const ext = (voice!.path.split(".").pop() || "webm").toLowerCase();
        const fd = new FormData();
        fd.append("chat_id", String(chat_id));
        fd.append("caption", `توجيه صوتي — ${t.title}`.slice(0, 1000));
        // MP3 يُرسل كمقطع صوتي يُشغَّل داخل تلقرام مباشرة؛ غيره يُرسل كملف
        const isMp3 = (voice!.mime || "").includes("mpeg") || ext === "mp3";
        const field = isMp3 ? "audio" : "document";
        fd.append(field, new File([blob], `توجيه-العميد.${ext}`, { type: voice!.mime || "audio/webm" }));
        if (isMp3) { fd.append("title", "توجيه سعادة العميد"); fd.append("performer", "عميد كلية الشريعة"); if (voice!.duration_s) fd.append("duration", String(voice!.duration_s)); }
        await fetch(`https://api.telegram.org/bot${TOKEN}/${isMp3 ? "sendAudio" : "sendDocument"}`, { method: "POST", body: fd });
      } catch (e) { console.error(e); }
    }
  }
  return { sent: ids.length };
}

async function onSetup() {
  const secret = await webhookSecret();
  const me = await tg("getMe", {});
  const hook = await tg("setWebhook", {
    url: "https://nwdmnjpzkkqtksetrelk.supabase.co/functions/v1/telegram",
    secret_token: secret, allowed_updates: ["message"], drop_pending_updates: true,
  });
  if (me?.result?.username) await sb.from("settings").update({ telegram_bot_username: me.result.username }).eq("id", 1);
  await tg("setMyCommands", { commands: [{ command: "status", description: "حالة اشتراكي في التنبيهات" }, { command: "stop", description: "إيقاف التنبيهات" }] });
  return { bot: me?.result?.username ?? null, webhook: hook?.ok ?? false };
}

async function onTelegram(update: any) {
  const m = update?.message;
  if (!m?.chat?.id || m.chat.type !== "private") return;
  const chat_id = m.chat.id, text = String(m.text ?? "").trim();
  const name = [m.from?.first_name, m.from?.last_name].filter(Boolean).join(" ");
  if (text.startsWith("/start")) {
    const code = text.split(/\s+/)[1] ?? "";
    const { data: st } = await sb.from("settings").select("telegram_join_code").eq("id", 1).maybeSingle();
    if (code && st?.telegram_join_code && code === st.telegram_join_code) {
      await sb.from("notify_recipients").upsert({ chat_id, name, username: m.from?.username ?? null, active: true });
      await tg("sendMessage", { chat_id, text: `أهلاً ${esc(name)} 👋\nتم تسجيلك لتلقي تنبيهات بوابة الطلبات الاستثنائية — كلية الشريعة:\n• الطلبات الجديدة\n• استكمال الطلاب لطلباتهم\n• ملخص المتأخرات (الأحد–الخميس 8:00 و 11:45)\n\nلإيقاف التنبيهات أرسل /stop`, parse_mode: "HTML" });
    } else {
      await tg("sendMessage", { chat_id, text: "هذا البوت خاص بمكتب عميد كلية الشريعة. للتسجيل استخدم رابط الانضمام من لوحة الطلبات." });
    }
    return;
  }
  if (text === "/stop") {
    await sb.from("notify_recipients").update({ active: false }).eq("chat_id", chat_id);
    await tg("sendMessage", { chat_id, text: "أُوقفت التنبيهات. لإعادة التفعيل استخدم رابط الانضمام من لوحة الطلبات." });
    return;
  }
  if (text === "/status") {
    const { data } = await sb.from("notify_recipients").select("active").eq("chat_id", chat_id).maybeSingle();
    await tg("sendMessage", { chat_id, text: data?.active ? "✅ التنبيهات مفعّلة لك." : "التنبيهات غير مفعّلة لك." });
  }
}

Deno.serve(async (req) => {
  if (!TOKEN) return json({ error: "TELEGRAM_BOT_TOKEN not set" }, 500);
  if (req.method !== "POST") return json({ ok: true });
  // messages from Telegram itself (verified by the secret header set in setWebhook)
  const tgSecret = req.headers.get("x-telegram-bot-api-secret-token");
  if (tgSecret !== null) {
    if (tgSecret !== await webhookSecret()) return json({ error: "bad secret" }, 401);
    try { await onTelegram(await req.json()); } catch (e) { console.error(e); }
    return json({ ok: true });
  }
  const body = await req.json().catch(() => ({}));
  try {
    switch (body.type) {
      case "new": return json(await onNew(body.id));
      case "completed": return json(await onCompleted(body.id));
      case "digest": return json(await onDigest());
      case "enjaz": return json(await onEnjaz(body.id));
      case "setup": return json(await onSetup());
      default: return json({ error: "unknown type" }, 400);
    }
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
