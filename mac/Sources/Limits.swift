import Foundation

/// Fetches the real subscription limits, straight from Anthropic.
///
/// WHY THIS EXISTS
/// ---------------
/// Claude Code keeps the percentages in a cache in ~/.claude.json with a
/// 5-minute deadline. Except the cache does not refresh itself: it is
/// rewritten when an API response carries the limit headers. If you go days
/// without opening the usage panel, the number on disk sits still — measured,
/// three days.
///
/// Here we make the same call Claude Code makes. The endpoint came from
/// reading its own binary:
///
///     fetchUtilization: GET /api/oauth/usage
///
/// ABOUT THE CREDENTIAL
/// --------------------
/// The access token belongs to Claude Code and lives in the macOS keychain.
/// This app asks the system, and it is **macOS** that decides. Without your
/// authorization there is no read: the app falls back to the on-disk cache and
/// reports its age.
///
/// Asking is deliberately rare. The token is read once and kept until it
/// expires, and the read goes through `/usr/bin/security`, which the item
/// already trusts — `toolRead` explains why that matters and what was
/// happening before.
///
/// The token never leaves your machine. It goes in a header to
/// api.anthropic.com and nowhere else. The bridge never even sees it — what
/// travels to it is only the result, over 127.0.0.1.
enum Limits {

    /// The keychain item Claude Code creates when it authenticates.
    private static let service = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    enum Failure: Error, Equatable {
        case noCredential(OSStatus)   // includes the "you declined" case
        case noToken
        /// The keychain neither allowed nor refused: it is waiting for an
        /// answer that never came.
        case keychainStuck
        /// The status and, when the server sends it, Retry-After in seconds.
        /// We keep the value because a 429 without a backoff becomes a
        /// permanent 429.
        case http(Int, TimeInterval?)
        /// Read from the credential itself, not guessed from a status code.
        case expired(Date)
        case network(String)

        var description: String {
            switch self {
            case .noCredential(let s) where s == errSecUserCanceled:
                return "keychain access declined"
            case .noCredential(let s) where s == errSecItemNotFound:
                return "Claude Code credential not found"
            case .noCredential(let s):
                // The number matters: without it, "it did not work" is
                // undebuggable.
                return "keychain refused (status \(s))"
            case .noToken:
                return "credential has no access token"
            case .keychainStuck:
                return "keychain did not answer — is there a dialog waiting?"
            case .expired(let at):
                let f = DateFormatter()
                f.dateFormat = "dd/MM HH:mm"
                return "credential expired at \(f.string(from: at)) — open Claude Code"
            case .http(401, _), .http(403, _):
                // NOT "expired". This code said exactly that for a long time
                // and it was wrong: the credential was valid and the token
                // being sent belonged to another service. Report what the
                // server said and let the reader draw the conclusion.
                return "Anthropic rejected the credential (401/403)"
            case .http(let c, _):
                return "Anthropic answered \(c)"
            case .network(let m):
                return m
            }
        }
    }

    // MARK: - keychain

    /// The token we already read, kept until it expires.
    ///
    /// Not an optimisation. It is half of the answer to the dialog that came
    /// back about ten times a day: every read of Claude Code's item is another
    /// chance for macOS to ask (see `toolRead` for why it asks), and this app
    /// reads on a 10-minute floor and a 1-hour ceiling. The credential is
    /// valid for hours. Re-reading it on every fetch bought nothing and cost a
    /// question.
    private static let lock = NSLock()
    private static var cached: (token: String, until: Date)?

    /// Called when Anthropic rejects the token: the cache is then WRONG, and
    /// the expiry date it was keyed on has stopped being evidence of anything.
    /// Without this, a credential rotated early — a re-login in Claude Code
    /// does exactly that — would keep failing until the dead token's own
    /// expiry came round.
    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    private nonisolated static func token() throws -> String {
        lock.lock()
        let hit = cached
        lock.unlock()
        // A minute of margin: a token that expires mid-request is a 401 we can
        // see coming.
        if let c = hit, c.until.timeIntervalSinceNow > 60 { return c.token }

        // Through the tool first. It is the path that does not ask.
        if let data = toolRead() { return try parse(data) }

        // And if that fails, ask the keychain ourselves — dialog and all. This
        // is the old path, kept because it is the one that still works if
        // Claude Code ever stops writing the item through `security`.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure.noCredential(status)
        }
        return try parse(data)
    }

    /// Reads the item by asking `/usr/bin/security` for it, instead of asking
    /// the keychain directly.
    ///
    /// WHY THE DETOUR
    /// --------------
    /// "Always Allow" was being undone several times a day, and the signature
    /// was not the reason: since create-identity.sh the app is signed by a
    /// stable identity, and the item's ACL still lists it as authorised —
    ///
    ///     0: /Users/…/Wisp.app (OK)
    ///        requirement: identifier "com.marciovicente.wisp" and
    ///                     certificate leaf = H"b158…"
    ///
    /// What gets undone is the OTHER list. macOS checks the ACL and then the
    /// PARTITION LIST, and Claude Code saves the credential by shelling out to
    /// `security add-generic-password -U`; an update through that tool rewrites
    /// the partition list as `apple-tool:`, dropping the entry your password
    /// added. It rewrites on every token refresh, and the item is shared with
    /// the OAuth grant of every connected MCP server — which is all "ten times
    /// a day" ever was. The proof is in the item: the ACL had accumulated five
    /// Wisp entries, one per build, while the partition list held exactly one.
    ///
    /// So we ask through the one caller both lists already trust: `security`
    /// is in the ACL, and `apple-tool:` is the partition entry Claude Code
    /// itself keeps putting back. Nothing is being circumvented — that same
    /// command reads the item from any shell of yours today. The token still
    /// goes nowhere but api.anthropic.com.
    ///
    /// Returns nil and never throws: every failure here falls back to the
    /// direct read above.
    private static func toolRead() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }

        // With a deadline, for the same reason the direct read has one: if the
        // ACL ever stops trusting the tool, `security` blocks on the very
        // dialog we are avoiding. Killing the child takes the dialog down with
        // it, which the direct path cannot do.
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global(qos: .userInitiated).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + 8) == .success else {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return payload(box.data)
    }

    /// `security -w` prints the value as text when it is text, and as a hex
    /// string when it is not. Claude Code writes the item with `-X`, raw
    /// bytes, so which of the two comes back is not something to guess at:
    /// accept both.
    private static func payload(_ out: Data) -> Data? {
        let s = String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("{") { return Data(s.utf8) }
        let chars = Array(s)
        guard chars.count % 2 == 0, chars.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i ... i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        return Data(bytes)
    }

    /// The credential as Claude Code writes it — same shape whichever of the
    /// two reads brought it here.
    private static func parse(_ data: Data) throws -> String {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.noToken
        }

        // The Claude entry EXPLICITLY, not "the first accessToken anywhere".
        //
        // This keychain item is shared. Besides claudeAiOauth it now holds
        // mcpOAuth — one OAuth grant per connected MCP server, each with its
        // own accessToken. The depth-first search below happily returned one
        // of those, and a Sentry token sent to api.anthropic.com comes back
        // "Invalid bearer token".
        //
        // The cost of that was not a broken feature, it was a LYING one: the
        // 401 got reported as "credential expired — open Claude Code", so the
        // fix on offer was to re-login and repair something that was never
        // broken. Measured: the credential had 2.2 hours left, and the right
        // token answered 200 on the first try.
        if let claude = raw["claudeAiOauth"] as? [String: Any] {
            let expiry = (claude["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            if let expiry, expiry < Date() {
                // Say it only when it is TRUE — and do not spend a request to
                // find out something we can read locally.
                throw Failure.expired(expiry)
            }
            if let t = find(claude, key: "accessToken") {
                // Only what we can date goes in the cache. Holding a token
                // with no known expiry means guessing how long it lives, and a
                // wrong guess here is a 401 the app reports as something else.
                if let expiry {
                    lock.lock()
                    cached = (t, expiry)
                    lock.unlock()
                }
                return t
            }
        }

        // No claudeAiOauth: fall back to the old depth search, but with the
        // MCP subtree removed. Keeps the resilience to renesting that the
        // search was written for, without the contamination that made it wrong.
        var semMcp = raw
        semMcp.removeValue(forKey: "mcpOAuth")
        guard let t = find(semMcp, key: "accessToken") else { throw Failure.noToken }
        return t
    }

    /// The credential format is undocumented and has already changed nesting
    /// level between versions. Searching for the key at any depth costs
    /// nothing and survives reorganisation.
    private static func find(_ node: Any, key: String) -> String? {
        if let d = node as? [String: Any] {
            for (k, v) in d {
                if k.caseInsensitiveCompare(key) == .orderedSame,
                   let s = v as? String, !s.isEmpty { return s }
                if let found = find(v, key: key) { return found }
            }
        }
        if let a = node as? [Any] {
            for v in a { if let found = find(v, key: key) { return found } }
        }
        return nil
    }

    // MARK: - fetching

    /// Returns the raw utilization object, exactly as Anthropic sent it.
    /// The bridge is what interprets it — it already knows the shape from the
    /// cache.
    static func fetch() async throws -> [String: Any] {
        // OFF the main actor, necessarily.
        //
        // SecItemCopyMatching is synchronous and, when macOS decides to ask for
        // your authorization, it only returns after you answer the dialog.
        // Called from the main actor, that freezes the entire interface while
        // the window waits — and the panel locks up at exactly the moment it
        // needs to explain what is going on.
        let work = Task.detached(priority: .userInitiated) { try token() }

        // With a DEADLINE, because the wait can be infinite.
        //
        // SecItemCopyMatching only returns after you answer the dialog, and
        // nobody is obliged to be at the machine when it appears — the
        // fallback path can still meet one, and an ad-hoc build meets it every
        // time, being a different app to macOS on every rebuild. Waiting
        // forever is the worst of the failures available: no data, no error,
        // and a panel showing an old number as if nothing had happened. That is
        // how a stale reading becomes invisible.
        //
        // The deadline does not cancel the read — a blocking C call is not
        // interruptible — it stops US from waiting on it. The dialog stays up,
        // and if you authorize it later the next fetch goes straight through.
        let t = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await work.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                throw Failure.keychainStuck
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.noToken }
            return first
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else { throw Failure.network("invalid response") }
        guard http.statusCode == 200 else {
            // Retry-After can arrive in seconds or as an HTTP date. We only
            // handle the first: it is what Anthropic sends, and guessing at the
            // second would mean inventing a backoff on a format we have not
            // seen.
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Failure.http(http.statusCode, ra)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.network("response is not JSON")
        }
        return obj
    }

    /// Tells the bridge why it did not work, so the reason shows up in /app
    /// instead of staying trapped inside the app. Diagnosing "it is using the
    /// cache" without knowing the cause is guesswork.
    static func reportFailure(_ reason: String, port: Int) async {
        await post(["error": reason], port: port)
    }

    /// Hands it to the bridge, which then prefers this over the on-disk cache.
    static func deliver(_ utilization: [String: Any], port: Int) async {
        await post(utilization, port: port)
    }

    private static func post(_ bodyObj: [String: Any], port: Int) async {
        guard let body = try? JSONSerialization.data(withJSONObject: bodyObj) else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/limits")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }
}
