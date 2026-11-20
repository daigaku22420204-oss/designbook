// デザインブック ↔ Supabase 接続レイヤー
// アプリ本体（index.html）が使う「db / user / assets / downloads」を Supabase で実装します。
(function () {
  "use strict";
  const CFG = window.DESIGNBOOK_CONFIG || {};
  const $ = s => document.querySelector(s);
  let sb = null, uid = null, email = null, isAdmin = false;
  const listeners = new Set();
  const parentOf = p => p.replace(/\/[^/]+$/, "");
  const rid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

  /* ---------- errors ---------- */
  function mapErr(e) {
    const m = (e && (e.message || e.details)) || "";
    if (/note_quota_exceeded/.test(m)) return { code: "quota_exceeded", message: "ノートの容量の上限に達しました" };
    if ((e && e.code === "42501") || /row-level security|permission denied/i.test(m)) return { code: "invalid_argument", message: m };
    return { code: "unavailable", message: m };
  }

  /* ---------- db ---------- */
  const snapDoc = (path, data) => ({
    id: path.split("/").pop(), exists: data !== undefined && data !== null,
    data: () => (data === null ? undefined : data), metadata: { fromCache: false, hasPendingWrites: false }
  });
  const qsnap = rows => { const docs = rows.map(r => snapDoc(r.path, r.data)); return { docs, size: docs.length, empty: !docs.length, docChanges: () => [], metadata: { fromCache: false, hasPendingWrites: false } }; };
  const applyFilters = (rows, f) => rows.filter(r => f.every(([k, op, v]) => op === "==" ? (r.data && r.data[k] === v) : true));

  async function getDoc(path) {
    const { data, error } = await sb.from("docs").select("data").eq("path", path).maybeSingle();
    if (error) throw mapErr(error);
    return data ? data.data : undefined;
  }
  async function getColl(coll) {
    const out = []; let from = 0;
    for (;;) {
      const { data, error } = await sb.from("docs").select("path,data").eq("coll", coll).range(from, from + 999);
      if (error) throw mapErr(error);
      out.push(...data); if (data.length < 1000) break; from += 1000;
    }
    return out;
  }
  function emit(L) {
    try {
      if (L.type === "coll") L.next(qsnap(applyFilters([...L.rows].map(([path, data]) => ({ path, data })), L.filters)));
      else L.next(snapDoc(L.path, L.data));
    } catch (e) { console.error(e); }
  }
  function applyLocal(path, data) {
    const par = parentOf(path);
    for (const L of listeners) {
      if (L.type === "coll" && L.path === par) { if (data === undefined) L.rows.delete(path); else L.rows.set(path, data); emit(L); }
      else if (L.type === "doc" && L.path === path) { L.data = data; emit(L); }
    }
  }
  async function load(L) {
    try {
      if (L.type === "coll") { const rows = await getColl(L.path); if (!L.alive) return; L.rows = new Map(rows.map(r => [r.path, r.data])); }
      else { const d = await getDoc(L.path); if (!L.alive) return; L.data = d; }
      emit(L);
    } catch (e) { if (L.onErr) L.onErr(e); }
  }
  function query(coll, filters) {
    const q = {
      path: coll,
      where: (f, op, v) => query(coll, [...filters, [f, op, v]]),
      orderBy: () => q, limit: () => q,
      doc: id => doc(coll + "/" + (id || rid())),
      add: async data => { const d = doc(coll + "/" + rid()); await d.set(data); return d; },
      get: async () => qsnap(applyFilters(await getColl(coll), filters)),
      onSnapshot(next, onErr) {
        const L = { type: "coll", path: coll, filters, rows: new Map(), next, onErr, alive: true };
        listeners.add(L); load(L);
        return () => { L.alive = false; listeners.delete(L); };
      }
    };
    return q;
  }
  function doc(path) {
    return {
      id: path.split("/").pop(), path,
      get: async () => snapDoc(path, await getDoc(path)),
      async set(data) {
        const { error } = await sb.from("docs").upsert({ path, data });
        if (error) throw mapErr(error);
        applyLocal(path, data);
      },
      async update(patch) {
        const cur = await getDoc(path);
        if (!cur) throw { code: "invalid_argument", message: "missing document" };
        await this.set(Object.assign({}, cur, patch));
      },
      async delete() {
        const { error } = await sb.from("docs").delete().eq("path", path);
        if (error) throw mapErr(error);
        applyLocal(path, undefined);
      },
      onSnapshot(next, onErr) {
        const L = { type: "doc", path, next, onErr, alive: true, data: undefined };
        listeners.add(L); load(L);
        return () => { L.alive = false; listeners.delete(L); };
      },
      collection: c => query(path + "/" + c, [])
    };
  }
  const db = { doc, collection: c => query(c, []) };

  function startRealtime() {
    let wasDown = false;
    sb.channel("docs-changes")
      .on("postgres_changes", { event: "*", schema: "public", table: "docs" }, async payload => {
        const path = (payload.new && payload.new.path) || (payload.old && payload.old.path);
        if (!path) return;
        const par = parentOf(path);
        const wanted = [...listeners].some(L => (L.type === "coll" && L.path === par) || (L.type === "doc" && L.path === path));
        if (!wanted) return;
        if (payload.eventType === "DELETE") { applyLocal(path, undefined); return; }
        let data = payload.new && payload.new.data;
        if (data === undefined) { try { data = await getDoc(path); } catch (e) { return; } }
        applyLocal(path, data);
      })
      .subscribe(status => {
        if (status === "SUBSCRIBED") { if (wasDown) resync(); wasDown = false; }
        else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") wasDown = true;
      });
    document.addEventListener("visibilitychange", () => { if (!document.hidden) resync(); });
  }
  let resyncT = 0;
  function resync() { const now = Date.now(); if (now - resyncT < 5000) return; resyncT = now; for (const L of listeners) load(L); }

  /* ---------- user ---------- */
  const user = {
    id: async () => uid,
    me: async () => ({ id: uid, name: "", avatarUrl: "", color: "#2B45D9", email, isOwner: isAdmin, canEdit: isAdmin }),
    isOwner: async () => isAdmin,
    canEdit: async () => isAdmin,
    can: async () => true,
    profiles: async ids => Object.fromEntries([].concat(ids).map(i => [i, { id: i, name: "", color: "#2B45D9", isMe: i === uid, guest: false }]))
  };

  /* ---------- assets (Supabase Storage) ---------- */
  const EXT = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "image/svg+xml": "svg", "application/pdf": "pdf", "text/plain": "txt", "text/csv": "csv", "application/json": "json", "text/markdown": "md", "video/mp4": "mp4", "video/webm": "webm" };
  const assets = {
    async upload(blob, opts = {}) {
      const folder = opts.folder || "post";
      const type = opts.type || blob.type || "application/octet-stream";
      const ext = opts.ext || EXT[type] || "bin";
      const name = `${uid}/${folder}/${rid()}.${ext}`;
      const { error } = await sb.storage.from("media").upload(name, blob, { contentType: type, cacheControl: "31536000", upsert: false });
      if (error) {
        const m = error.message || "";
        const code = /row-level security|policy|unauthori[sz]ed|403/i.test(m) ? (folder === "note" ? "quota_or_state" : "not_granted")
          : /size|large|413/i.test(m) ? "too_large" : "upstream_error";
        throw { code, message: m };
      }
      const { data } = sb.storage.from("media").getPublicUrl(name);
      return { id: name, url: data.publicUrl, sizeBytes: blob.size, contentType: type };
    },
    async delete(id) { if (!id || id.startsWith("assets/")) return { deleted: false }; await sb.storage.from("media").remove([id]); return { deleted: true }; },
    async list() { return { assets: [], usage: {} }; }
  };

  /* ---------- downloads (browser save) ---------- */
  const downloads = {
    async save({ filename, data }) {
      const blob = data instanceof Blob ? data : new Blob([data]);
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a"); a.href = url; a.download = filename || "download";
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
      return { status: "saved" };
    }
  };

  /* ---------- extras used by the web version ---------- */
  const extras = {
    async usage() { const { data, error } = await sb.rpc("my_usage"); if (error) throw mapErr(error); return data; },
    async signOut() { await sb.auth.signOut(); location.reload(); },
    async listAllowed() { const { data, error } = await sb.from("allowed_emails").select("email,is_admin,created_at").order("created_at"); if (error) throw mapErr(error); return data; },
    async addAllowed(addr) { const { error } = await sb.from("allowed_emails").insert({ email: addr.trim().toLowerCase(), is_admin: false }); if (error) throw mapErr(error); },
    async removeAllowed(addr) { const { error } = await sb.from("allowed_emails").delete().eq("email", addr); if (error) throw mapErr(error); },
    get email() { return email; }
  };

  /* ---------- login screen ---------- */
  function show(id) { document.querySelectorAll(".gate-step").forEach(el => el.hidden = el.id !== id); $("#gate").hidden = false; }
  function loginFlow() {
    return new Promise(resolve => {
      show("gate-email");
      let addr = "";
      const msg = $("#gateMsg");
      sb.auth.onAuthStateChange((ev, s) => { if (s && (ev === "SIGNED_IN" || ev === "TOKEN_REFRESHED")) resolve(s); });
      $("#gateEmailForm").addEventListener("submit", async e => {
        e.preventDefault();
        addr = $("#gateEmail").value.trim().toLowerCase();
        if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(addr)) { msg.textContent = "メールアドレスの形を確認してください。"; return; }
        const btn = $("#gateEmailBtn"); btn.disabled = true; msg.textContent = "確認中…";
        try {
          const { data: ok, error } = await sb.rpc("check_email_allowed", { addr });
          if (error) throw error;
          if (!ok) { msg.textContent = "このメールアドレスは招待されていません。管理者に招待を頼んでください。"; btn.disabled = false; return; }
          const { error: e2 } = await sb.auth.signInWithOtp({ email: addr, options: { emailRedirectTo: location.origin + location.pathname, shouldCreateUser: true } });
          if (e2) throw e2;
          msg.textContent = ""; $("#gateSentTo").textContent = addr; show("gate-sent");
          setTimeout(() => $("#gateCode").focus(), 50);
        } catch (err) {
          const m = (err && err.message) || "";
          msg.textContent = /rate|too many|seconds/i.test(m) ? "メールの送信回数の上限に達しました。しばらく待ってからもう一度お試しください。" : "メールを送れませんでした。時間をおいてもう一度お試しください。";
        }
        btn.disabled = false;
      });
      $("#gateCodeForm").addEventListener("submit", async e => {
        e.preventDefault();
        const token = $("#gateCode").value.replace(/\s/g, "");
        const m2 = $("#gateMsg2");
        if (!/^\d{6,10}$/.test(token)) { m2.textContent = "メールに書かれた数字を入力してください。"; return; }
        m2.textContent = "確認中…";
        const { data, error } = await sb.auth.verifyOtp({ email: addr, token, type: "email" });
        if (error || !data.session) { m2.textContent = "コードが正しくないか、期限が切れています。もう一度メールを送ってください。"; return; }
        resolve(data.session);
      });
      $("#gateBack").addEventListener("click", () => { show("gate-email"); });
    });
  }

  async function start() {
    if (!window.supabase || !CFG.SUPABASE_URL || /YOUR-PROJECT|YOUR-ANON/.test(CFG.SUPABASE_URL + CFG.SUPABASE_ANON_KEY)) {
      show("gate-setup"); return null;
    }
    sb = window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY, {
      auth: { flowType: "implicit", persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
    });
    let { data: { session } } = await sb.auth.getSession();
    if (!session) session = await loginFlow();
    uid = session.user.id; email = session.user.email;
    const { data: ok, error } = await sb.rpc("is_allowed");
    if (error) { $("#gateErrText").textContent = "サーバーに接続できませんでした。時間をおいて開き直してください。（" + (error.message || "") + "）"; show("gate-error"); return null; }
    if (!ok) { $("#gateNoText").textContent = email + " は招待リストに入っていません。管理者に招待を頼んでください。"; show("gate-not-invited"); $("#gateSignOut").onclick = () => extras.signOut(); return null; }
    const { data: adm } = await sb.rpc("is_admin"); isAdmin = !!adm;
    sb.auth.onAuthStateChange(ev => { if (ev === "SIGNED_OUT") location.reload(); });
    $("#gate").hidden = true;
    if (/access_token=|error_description=/.test(location.hash)) history.replaceState(null, "", location.pathname + "#explore");
    startRealtime();
    return { use: async n => ({ db, user, assets, downloads })[n] || null };
  }

  window.DesignBookBackend = { start, extras };
})();
