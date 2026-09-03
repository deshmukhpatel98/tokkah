import Foundation

// ── ONE HTTP SESSION, AND NOTHING ON DISK ────────────────────────────────────
//
// Every request this app makes used `URLSession.shared`, and `URLSession.shared`
// keeps a disk cache: ~/Library/Caches/com.tokkah.tk/Cache.db, a SQLite file.
// Read back on 2026-09-03, it held the rendezvous URLs of every call this Mac had
// made -- `/api/room/<ROOM>/rv?me=...&addr=<public ip:port>&local=<lan ip:port>`.
// The room code is the rendezvous secret and, until 0.128, was the key salt; the
// header of Telemetry.swift says it "must never leave the two machines", and the
// two machines were writing it to a database on disk, indexed, for ever.
//
// The same file is also why two copies of the app on one Mac (every rig, and a
// person with a second instance open) crashed inside CFNetwork: both processes
// wrote one SQLite database at once, and the hostile-peer fuzzer's target died in
// `NSURLStorageURLCacheDB` with a segmentation fault -- heap corruption that was
// nothing to do with the packets it was being sent.
//
// So: one ephemeral session for the whole app. No disk cache, no cookie jar, no
// credential store, and every request refuses cached answers anyway -- nothing
// this app fetches is worth caching (a rendezvous is live or it is nothing, a
// manifest is checked by hash, a face is small). The legacy database is deleted
// once at launch; a secret already written is a secret to remove, not to leave.
enum Http {
  static let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCredentialStorage = nil
    return URLSession(configuration: c)
  }()

  /// Removes the caches earlier builds left behind. Off the main thread, once.
  static func wipeLegacyCache() {
    Thread {
      let fm = FileManager.default
      let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
      var removed = 0
      for name in ["com.tokkah.tk", "tk", "Tokkah", "com.tokkah.tk.watch"] {
        let d = base.appendingPathComponent(name)
        guard let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
        for f in items where f.lastPathComponent.hasPrefix("Cache.db") || f.lastPathComponent == "fsCachedData" {
          if (try? fm.removeItem(at: f)) != nil { removed += 1 }
        }
      }
      if removed > 0 { fputs("http: removed \(removed) legacy URL-cache file(s) -- they held room codes\n", stderr) }
    }.start()
  }
}
