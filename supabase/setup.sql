-- =====================================================================
-- デザインブック Supabase セットアップ
-- Supabase の「SQL Editor」にこのファイルの内容をすべて貼り付けて「Run」を押してください。
-- 何度実行しても壊れないように作ってあります。
--
-- ★ 実行する前に、一番下の「管理者のメールアドレス」を自分のアドレスに書き換えてください。
-- =====================================================================

-- ---------- 上限の設定（ここを変えると上限が変わります） ----------
create or replace function public.note_quota_bytes() returns bigint
language sql immutable as $$ select (40 * 1024 * 1024)::bigint $$;      -- ノート：1人40MB

create or replace function public.note_photo_limit() returns integer
language sql immutable as $$ select 20 $$;                               -- ノートの写真：1人20枚

-- ---------- 招待リスト ----------
create table if not exists public.allowed_emails (
  email      text primary key,
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.allowed_emails enable row level security;

create or replace function public.is_allowed() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.allowed_emails a
                 where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.allowed_emails a
                 where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', '')) and a.is_admin);
$$;

-- ログイン画面から「招待されているか」を確認するための関数（ログイン前でも呼べる）
create or replace function public.check_email_allowed(addr text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.allowed_emails a where lower(a.email) = lower(trim(addr)));
$$;
grant execute on function public.check_email_allowed(text) to anon, authenticated;

drop policy if exists allowed_admin_select on public.allowed_emails;
drop policy if exists allowed_admin_insert on public.allowed_emails;
drop policy if exists allowed_admin_update on public.allowed_emails;
drop policy if exists allowed_admin_delete on public.allowed_emails;
create policy allowed_admin_select on public.allowed_emails for select to authenticated using (public.is_admin());
create policy allowed_admin_insert on public.allowed_emails for insert to authenticated with check (public.is_admin());
create policy allowed_admin_update on public.allowed_emails for update to authenticated using (public.is_admin()) with check (public.is_admin());
-- 管理者は自分自身を削除できない（締め出し防止）
create policy allowed_admin_delete on public.allowed_emails for delete to authenticated
  using (public.is_admin() and lower(email) <> lower(coalesce(auth.jwt() ->> 'email', '')));

-- ---------- データ（投稿・いいね・コメント・プロフィール・ノート） ----------
-- path の例：posts/<ユーザーID>、comments/<ユーザーID>、data/users/<ユーザーID>/<ページID>/c/<チャンクID>
create table if not exists public.docs (
  path       text primary key,
  coll       text generated always as (regexp_replace(path, '/[^/]+$', '')) stored,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists docs_coll_idx on public.docs (coll);
alter table public.docs enable row level security;

-- 自分が書き込んでよい場所か
create or replace function public.can_write_path(p text) returns boolean
language sql stable as $$
  select case split_part(p, '/', 1)
    when 'posts'    then split_part(p, '/', 2) = auth.uid()::text and split_part(p, '/', 3) = ''
    when 'likes'    then split_part(p, '/', 2) = auth.uid()::text and split_part(p, '/', 3) = ''
    when 'comments' then split_part(p, '/', 2) = auth.uid()::text and split_part(p, '/', 3) = ''
    when 'profiles' then split_part(p, '/', 2) = auth.uid()::text and split_part(p, '/', 3) = ''
    when 'img'      then split_part(p, '/', 2) = auth.uid()::text
    when 'data'     then split_part(p, '/', 2) = 'users' and split_part(p, '/', 3) = auth.uid()::text
    else false
  end;
$$;

-- 管理者が他の人の投稿・コメントを削除（整理）できる場所か
create or replace function public.admin_can_moderate(p text) returns boolean
language sql stable as $$
  select public.is_admin() and split_part(p, '/', 1) in ('posts', 'comments') and split_part(p, '/', 3) = '';
$$;

drop policy if exists docs_read   on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;
-- 読む：招待された人だけ。data/users/<ID>/ 以下（非公開の採集・ノート）は本人だけ。
create policy docs_read on public.docs for select to authenticated using (
  public.is_allowed() and (
    split_part(path, '/', 1) <> 'data'
    or (split_part(path, '/', 2) = 'users' and split_part(path, '/', 3) = auth.uid()::text)
  )
);
create policy docs_insert on public.docs for insert to authenticated
  with check (public.is_allowed() and (public.can_write_path(path) or public.admin_can_moderate(path)));
create policy docs_update on public.docs for update to authenticated
  using      (public.is_allowed() and (public.can_write_path(path) or public.admin_can_moderate(path)))
  with check (public.is_allowed() and (public.can_write_path(path) or public.admin_can_moderate(path)));
create policy docs_delete on public.docs for delete to authenticated
  using (public.is_allowed() and (public.can_write_path(path) or public.admin_can_moderate(path)));

-- ノート容量の上限（1人あたり）をデータベース側で守る
create or replace function public.enforce_note_quota() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  owner text;
  used  bigint;
begin
  if new.path like 'data/users/%/%/c/%' then
    owner := split_part(new.path, '/', 3);
    select coalesce(sum(pg_column_size(d.data)), 0) into used
      from public.docs d
     where d.path like 'data/users/' || owner || '/%/c/%' and d.path <> new.path;
    if used + pg_column_size(new.data) > public.note_quota_bytes() then
      raise exception 'note_quota_exceeded';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists docs_note_quota on public.docs;
create trigger docs_note_quota before insert or update on public.docs
  for each row execute function public.enforce_note_quota();

-- リアルタイム更新（ほかの人の投稿やコメントがすぐ表示される）
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    execute 'alter publication supabase_realtime add table public.docs';
  end if;
end $$;

-- ---------- 写真の保存場所 ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', true, 20971520)
on conflict (id) do update set public = true, file_size_limit = 20971520;

create or replace function public.note_photo_count(uid uuid) returns integer
language sql stable security definer set search_path = public, storage as $$
  select count(*)::int from storage.objects o
   where o.bucket_id = 'media' and o.name like uid::text || '/note/%';
$$;

drop policy if exists media_insert on storage.objects;
drop policy if exists media_select on storage.objects;
drop policy if exists media_delete on storage.objects;
-- アップロード：招待された人が、自分のフォルダにだけ。ノートの写真は枚数上限あり。
create policy media_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'media' and public.is_allowed()
  and (storage.foldername(name))[1] = auth.uid()::text
  and (
    (storage.foldername(name))[2] in ('post', 'file', 'avatar')
    or ((storage.foldername(name))[2] = 'note' and public.note_photo_count(auth.uid()) < public.note_photo_limit())
  )
);
create policy media_select on storage.objects for select to authenticated
  using (bucket_id = 'media' and public.is_allowed());
create policy media_delete on storage.objects for delete to authenticated using (
  bucket_id = 'media' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin())
);

-- ---------- 使用量（設定画面とノート画面に表示） ----------
create or replace function public.my_usage() returns json
language sql stable security definer set search_path = public, storage as $$
  select json_build_object(
    'note_bytes',       (select coalesce(sum(pg_column_size(d.data)), 0) from public.docs d
                          where d.path like 'data/users/' || auth.uid()::text || '/%/c/%'),
    'note_quota',       public.note_quota_bytes(),
    'note_photos',      public.note_photo_count(auth.uid()),
    'note_photo_limit', public.note_photo_limit(),
    'db_bytes',         pg_database_size(current_database()),
    'storage_bytes',    (select coalesce(sum((o.metadata ->> 'size')::bigint), 0) from storage.objects o where o.bucket_id = 'media')
  )
  where public.is_allowed();
$$;

grant select, insert, update, delete on public.docs to authenticated;
grant select, insert, update, delete on public.allowed_emails to authenticated;

-- ---------- 公式アカウントの作例 ----------
insert into public.docs (path, data) values
  ('profiles/official', '{"avatar": null, "bio": "デザインブック編集部です。「どこが好きか」の書き方の見本として、オリジナルの作例を採集しています。#タグ の付け方の参考にどうぞ。", "color": "#13151B", "link": "", "name": "デザインブック公式", "updatedAt": 1794547000000}'::jsonb),
  ('posts/official', '{"items": [{"createdAt": 1794546000000, "genre": "広告", "id": "off6", "img": {"kind": "asset", "url": "assets/official/a6.jpg", "w": 1200, "h": 1600}, "no": 6, "note": "駅のホームに貼られることを想定したポスターの作例。画面のほとんどを余白にして、湯気の立つカップと縦書きのコピーだけを置いています。\n\n※デザインブック公式のオリジナル作例です。", "source": "デザインブック公式 作例", "tags": ["余白", "縦書き", "ポスター", "コピー"], "title": "余白で語るコーヒースタンドの駅広告", "updatedAt": 1794546000000, "why": "情報を足すのではなく引くことで、通りすがりの数秒でも「静かな朝」の空気が伝わるところ。縦書きのコピーを右上に寄せて、視線がコピーからカップへ流れる。", "imgs": [{"kind": "asset", "url": "assets/official/a6.jpg", "w": 1200, "h": 1600}], "files": []}, {"createdAt": 1794460000000, "genre": "Web・UI", "id": "off5", "img": {"kind": "asset", "url": "assets/official/a5.jpg", "w": 1600, "h": 1200}, "no": 5, "note": "ライトとダークの2画面で、カード型レイアウトの作例を作りました。角丸と余白の値をそろえて、別のアプリでも同じ家族に見えるようにしています。\n\n※デザインブック公式のオリジナル作例です。", "source": "デザインブック公式 作例", "tags": ["カードUI", "ダークモード", "アプリ", "等幅フォント"], "title": "献立アプリとふりかえりアプリのカードUI", "updatedAt": 1794460000000, "why": "大事な数字（12,480歩、7h 12m）だけを等幅フォントで大きくして、ラベルは控えめに。カードの色が多くても、角丸と余白がそろっているので散らからない。", "imgs": [{"kind": "asset", "url": "assets/official/a5.jpg", "w": 1600, "h": 1200}], "files": []}, {"createdAt": 1794370000000, "genre": "イラスト", "id": "off4", "img": {"kind": "asset", "url": "assets/official/a4.jpg", "w": 1200, "h": 1500}, "no": 4, "note": "線を使わず、色面だけで描いた夜の商店街のイラストの作例。紺色の背景に、窓と看板の暖色だけを置いています。\n\n※デザインブック公式のオリジナル作例です。", "source": "デザインブック公式 作例", "tags": ["フラット", "夜景", "配色", "商店街"], "title": "提灯の灯る夜の商店街", "updatedAt": 1794370000000, "why": "色数を絞って、暖かい色を「明かり」にだけ使っているところ。奥に向かって細くなる道で、自然に視線が人物へ集まる。", "imgs": [{"kind": "asset", "url": "assets/official/a4.jpg", "w": 1200, "h": 1500}], "files": []}, {"createdAt": 1794280000000, "genre": "パッケージ", "id": "off3", "img": {"kind": "asset", "url": "assets/official/a3.jpg", "w": 1200, "h": 1200}, "no": 3, "note": "上から見た4つの仕切りに、桜・青葉・月・雪をひとつずつ描いたパッケージの作例。中央の朱色の帯に「四季」の文字を置いています。\n\n※デザインブック公式のオリジナル作例です。", "source": "デザインブック公式 作例", "tags": ["和菓子", "和柄", "配色", "パッケージ"], "title": "四季をひと箱に詰めた和菓子のパッケージ", "updatedAt": 1794280000000, "why": "紺の外枠と朱の帯という強い2色で全体を締めて、中の4つの絵柄はやわらかい色にしているところ。箱を開ける前から季節の移り変わりが分かる。", "imgs": [{"kind": "asset", "url": "assets/official/a3.jpg", "w": 1200, "h": 1200}], "files": []}, {"createdAt": 1794190000000, "genre": "建築", "id": "off2", "img": {"kind": "asset", "url": "assets/official/a2.jpg", "w": 1600, "h": 1100}, "no": 2, "note": "ガラスの箱の前に、カラマツの縦ルーバーを440mm間隔で並べた図書館の立面図の作例。軒を深く出して、夏の日差しを遮る計画です。\n\n※デザインブック公式のオリジナル作例です。", "source": "デザインブック公式 作例", "tags": ["木造", "ルーバー", "立面図", "公共建築"], "title": "木製ルーバーのまちの図書館（南立面図）", "updatedAt": 1794190000000, "why": "ルーバーの影の部分を描き込むだけで、立体感と木の温かさが出るところ。人や木を添えると、建物の大きさが直感的に分かる。", "imgs": [{"kind": "asset", "url": "assets/official/a2.jpg", "w": 1600, "h": 1100}], "files": []}, {"createdAt": 1794100000000, "genre": "グラフィック", "id": "off1", "img": {"kind": "asset", "url": "assets/official/a1.jpg", "w": 1200, "h": 1680}, "no": 1, "note": "スイス・スタイルを意識した音楽祭のポスターの作例。同心円のモチーフと、太いサンセリフの英字を、厳密なグリッドの上に組んでいます。\n\n※デザインブック公式のオリジナル作例です。", "source": "デザインブック公式 作例", "tags": ["グリッド", "タイポグラフィ", "ポスター", "スイススタイル"], "title": "川辺の野外音楽祭のグリッドポスター", "updatedAt": 1794100000000, "why": "同心円が音の広がりやスピーカーに見えるところ。赤・黒・生成りの3色だけなのに、文字の大きさの差がはっきりしていて遠くからでも読める。", "imgs": [{"kind": "asset", "url": "assets/official/a1.jpg", "w": 1200, "h": 1680}], "files": []}], "updatedAt": 1794547000000}'::jsonb)
on conflict (path) do nothing;

-- ---------- 管理者のメールアドレス（★自分のアドレスに書き換えてから実行） ----------
insert into public.allowed_emails (email, is_admin) values ('YOUR_EMAIL@example.com', true)
on conflict (email) do update set is_admin = true;
