// デザインブックの設定ファイル
// Supabase の2つの値を貼り付けてください（手順書 SETUP.md の「4. アプリに接続情報を書き込む」）。
//   SUPABASE_URL      … Project URL（https://xxxx.supabase.co）
//   SUPABASE_ANON_KEY … Publishable key（sb_publishable_ で始まるキー）。sb_secret_ のキーは絶対に入れないでください。
// Publishable key は公開しても安全なキーです。データは招待リストと権限ルールで守られます。
window.DESIGNBOOK_CONFIG = {
  SUPABASE_URL: "https://hdvsoyknhjqfinumuiae.supabase.co/rest/v1/",
  SUPABASE_ANON_KEY: "sb_publishable__-_E672O1nu1QGLu5qEt0Q_zarBVP5W",

  // 機能のオン・オフ
  FEATURES: {
    // 投稿に PDF・DXF などの資料ファイルを添付する機能。
    // true にすると添付欄が表示されます（保存容量を多く使うので、必要になったときに）。
    files: false,
    // ノートに写真を貼る機能
    notePhotos: true
  },

  // 上限（表示用。実際の制限は supabase/setup.sql の数値と合わせてください）
  LIMITS: {
    noteMB: 40,          // 1人あたりのノート容量（MB）
    notePhotos: 20,      // 1人あたりのノートの写真枚数
    totalDbMB: 500,      // Supabase 無料プランのデータベース容量
    totalStorageMB: 1024 // Supabase 無料プランのファイル保存容量
  }
};
