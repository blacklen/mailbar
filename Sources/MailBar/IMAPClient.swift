import Foundation
import Network

struct Email: Identifiable, Sendable {
    let uid: UInt32
    let from: String
    let subject: String
    let date: Date?
    let url: URL

    var id: UInt32 { uid }
}

struct UnreadResult: Sendable {
    /// Every unread email in the inbox, not just the ones in `emails`.
    let unreadUIDs: Set<UInt32>
    /// The newest unread emails, newest first.
    let emails: [Email]
}

enum IMAPError: LocalizedError {
    case loginFailed
    case commandFailed(String)
    case connectionClosed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .loginFailed: return "Gmail rejected the login. Check your address and app password."
        case .commandFailed(let message): return "Gmail returned an error: \(message)"
        case .connectionClosed: return "Gmail closed the connection."
        case .timedOut: return "Gmail didn't respond in time."
        }
    }
}

enum Gmail {
    static func inboxURL(for email: String) -> URL {
        url(email: email, fragment: "inbox")
    }

    static func threadURL(for email: String, threadID: UInt64) -> URL {
        url(email: email, fragment: "inbox/" + String(threadID, radix: 16))
    }

    private static func url(email: String, fragment: String) -> URL {
        var components = URLComponents(string: "https://mail.google.com/mail/")!
        components.percentEncodedQuery = "authuser=" + (email.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? email)
        components.fragment = fragment
        return components.url!
    }
}

/// Talks to Gmail over IMAP. Checking is read-only: the inbox is opened with EXAMINE and headers
/// are fetched with BODY.PEEK. Only the markAsRead functions change anything.
enum IMAPClient {
    private static let host = "imap.gmail.com"
    private static let port: UInt16 = 993

    static func verify(account: Account) async throws {
        try await session(account) { _ in }
    }

    static func fetchUnread(account: Account, limit: Int) async throws -> UnreadResult {
        try await session(account) { connection in
            try await connection.command("EXAMINE INBOX")
            let uids = try await unreadPrimaryUIDs(connection)

            let newest = uids.sorted(by: >).prefix(limit)
            guard !newest.isEmpty else { return UnreadResult(unreadUIDs: Set(uids), emails: []) }

            let uidSet = newest.map(String.init).joined(separator: ",")
            let lines = try await connection.command(
                "UID FETCH \(uidSet) (UID INTERNALDATE X-GM-THRID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])"
            )
            let emails = lines
                .compactMap { parseFetch($0, accountEmail: account.email) }
                .sorted { $0.uid > $1.uid }
            return UnreadResult(unreadUIDs: Set(uids), emails: emails)
        }
    }

    static func markAsRead(account: Account, uids: [UInt32]) async throws {
        try await session(account) { connection in
            try await connection.command("SELECT INBOX")
            try await markSeen(uids, connection)
        }
    }

    /// Marks every unread email in the Primary tab as read and returns how many there were.
    static func markAllAsRead(account: Account) async throws -> Int {
        try await session(account) { connection in
            try await connection.command("SELECT INBOX")
            let uids = try await unreadPrimaryUIDs(connection)
            try await markSeen(uids, connection)
            return uids.count
        }
    }

    /// Unread UIDs in the Primary tab. X-GM-RAW takes Gmail's own search syntax.
    private static func unreadPrimaryUIDs(_ connection: IMAPConnection) async throws -> [UInt32] {
        var uids: [UInt32] = []
        for line in try await connection.command("UID SEARCH UNSEEN X-GM-RAW \"category:primary\"") where line.text.hasPrefix("* SEARCH") {
            uids += line.text.split(separator: " ").dropFirst(2).compactMap { UInt32($0) }
        }
        return uids
    }

    private static func markSeen(_ uids: [UInt32], _ connection: IMAPConnection) async throws {
        // Batches keep each command line a reasonable length.
        for start in stride(from: 0, to: uids.count, by: 500) {
            let batch = uids[start..<min(start + 500, uids.count)]
            try await connection.command("UID STORE \(batch.map(String.init).joined(separator: ",")) +FLAGS.SILENT (\\Seen)")
        }
    }

    private static func session<T>(_ account: Account, _ body: (IMAPConnection) async throws -> T) async throws -> T {
        let connection = IMAPConnection(host: host, port: port)
        defer { connection.close() }
        try await connection.open()
        try await connection.login(email: account.email, password: account.password)
        let result = try await body(connection)
        _ = try? await connection.command("LOGOUT")
        return result
    }

    // MARK: - Parsing

    private static let internalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter
    }()

    private static func parseFetch(_ line: IMAPLine, accountEmail: String) -> Email? {
        guard line.text.contains(" FETCH ("),
              let uid = number(after: "UID", in: line.text).flatMap({ UInt32($0) }),
              let headerData = line.literals.first else { return nil }

        let headers = MailHeaders.parse(headerData)
        let from = MailHeaders.displayName(headers["from"] ?? "")
        let subject = headers["subject"] ?? ""
        let url = number(after: "X-GM-THRID", in: line.text)
            .flatMap { UInt64($0) }
            .map { Gmail.threadURL(for: accountEmail, threadID: $0) } ?? Gmail.inboxURL(for: accountEmail)

        return Email(
            uid: uid,
            from: from.isEmpty ? "(unknown sender)" : from,
            subject: subject.isEmpty ? "(no subject)" : subject,
            date: internalDate(in: line.text),
            url: url
        )
    }

    private static func number(after key: String, in text: String) -> String? {
        guard let range = text.range(of: key + " ") else { return nil }
        let digits = text[range.upperBound...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : String(digits)
    }

    private static func internalDate(in text: String) -> Date? {
        guard let start = text.range(of: "INTERNALDATE \""),
              let end = text[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let value = text[start.upperBound..<end].trimmingCharacters(in: .whitespaces)
        return internalDateFormatter.date(from: value)
    }
}

// MARK: - Connection

/// One server response. Literals (`{n}` followed by n raw bytes) are pulled out into `literals`.
struct IMAPLine {
    let text: String
    let literals: [Data]
}

private final class ConnectionState: @unchecked Sendable {
    // Only touched on the connection's serial queue.
    var openResumed = false
    var timedOut = false
}

final class IMAPConnection {
    private static let timeout: TimeInterval = 30

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "MailBar.IMAP")
    private let state = ConnectionState()
    private var buffer = Data()
    private var nextTag = 1

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tls)
    }

    func open() async throws {
        let connection = connection, state = state

        // Hard limit for the whole session, so a stalled network can't hang a check forever.
        queue.asyncAfter(deadline: .now() + Self.timeout) {
            state.timedOut = true
            connection.cancel()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { newState in
                guard !state.openResumed else { return }
                switch newState {
                case .ready:
                    state.openResumed = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    state.openResumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    state.openResumed = true
                    continuation.resume(throwing: IMAPError.timedOut)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        _ = try await readResponse() // server greeting
    }

    func close() {
        connection.cancel()
    }

    func login(email: String, password: String) async throws {
        do {
            try await command("LOGIN \(quote(email)) \(quote(password))")
        } catch IMAPError.commandFailed(_) {
            throw IMAPError.loginFailed
        }
    }

    /// Sends a command and returns the untagged responses that came before its OK.
    @discardableResult
    func command(_ command: String) async throws -> [IMAPLine] {
        let tag = "A\(nextTag)"
        nextTag += 1
        try await send("\(tag) \(command)\r\n")

        var untagged: [IMAPLine] = []
        while true {
            let response = try await readResponse()
            guard response.text.hasPrefix(tag + " ") else {
                untagged.append(response)
                continue
            }
            let status = response.text.dropFirst(tag.count + 1)
            guard status.hasPrefix("OK") else { throw IMAPError.commandFailed(String(status)) }
            return untagged
        }
    }

    private func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func readResponse() async throws -> IMAPLine {
        var text = ""
        var literals: [Data] = []
        while true {
            let line = String(decoding: try await readLine(), as: UTF8.self)
            text += line
            guard let length = literalLength(line) else {
                return IMAPLine(text: text, literals: literals)
            }
            literals.append(try await readBytes(length))
        }
    }

    private func literalLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        return Int(line[line.index(after: open)..<line.index(before: line.endIndex)])
    }

    private func readLine() async throws -> Data {
        let crlf = Data("\r\n".utf8)
        while true {
            if let range = buffer.range(of: crlf) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            try await receiveMore()
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await receiveMore()
        }
        let bytes = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return bytes
    }

    private func receiveMore() async throws {
        let connection = connection, state = state
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if state.timedOut {
                    continuation.resume(throwing: IMAPError.timedOut)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(throwing: IMAPError.connectionClosed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
        buffer.append(data)
    }

    private func send(_ text: String) async throws {
        let connection = connection, state = state
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if state.timedOut {
                    continuation.resume(throwing: IMAPError.timedOut)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

// MARK: - Headers

enum MailHeaders {
    static func parse(_ data: Data) -> [String: String] {
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let unfolded = raw
            .replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\r\n\t", with: " ")

        var headers: [String: String] = [:]
        for line in unfolded.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = decodeEncodedWords(value)
        }
        return headers
    }

    /// `"Jane Doe" <jane@example.com>` → `Jane Doe`; a bare address is returned as-is.
    static func displayName(_ from: String) -> String {
        guard let open = from.firstIndex(of: "<") else { return from }
        let name = from[..<open]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !name.isEmpty { return name }
        return from[from.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
    }

    /// Decodes RFC 2047 encoded words such as `=?UTF-8?B?SGVsbG8=?=`.
    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?"),
              let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#) else { return value }

        // Whitespace between two adjacent encoded words is not part of the text.
        let joined = value.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        let source = joined as NSString
        var result = ""
        var position = 0
        for match in regex.matches(in: joined, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let decoded = decodeWord(
                charset: source.substring(with: match.range(at: 1)),
                encoding: source.substring(with: match.range(at: 2)).uppercased(),
                text: source.substring(with: match.range(at: 3))
            )
            result += decoded ?? source.substring(with: match.range)
            position = match.range.location + match.range.length
        }
        result += source.substring(from: position)
        return result
    }

    private static func decodeWord(charset: String, encoding: String, text: String) -> String? {
        let bytes: Data?
        if encoding == "B" {
            var base64 = text
            while base64.count % 4 != 0 { base64 += "=" }
            bytes = Data(base64Encoded: base64)
        } else {
            bytes = decodeQ(text)
        }
        guard let bytes else { return nil }

        let charsetName = charset.split(separator: "*").first.map(String.init) ?? charset
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charsetName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return String(data: bytes, encoding: .utf8) }
        return String(data: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)))
    }

    private static func decodeQ(_ text: String) -> Data {
        let chars = Array(text.utf8)
        var bytes = Data()
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "_") {
                bytes.append(0x20)
                i += 1
            } else if c == UInt8(ascii: "="), i + 2 < chars.count,
                      let byte = UInt8(String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                i += 3
            } else {
                bytes.append(c)
                i += 1
            }
        }
        return bytes
    }
}
