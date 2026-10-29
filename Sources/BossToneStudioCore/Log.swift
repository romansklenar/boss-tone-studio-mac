import Foundation

private let traceEnabled = ProcessInfo.processInfo.environment["BTS_TRACE"] == "1"

public func log(_ message: String) {
    print("[bts] \(message)")
}

/// Bridge traffic for `make trace`; silent unless `BTS_TRACE=1`.
public func trace(_ arrow: String, _ label: String, _ args: [String]) {
    guard traceEnabled else { return }
    print(traceLine(arrow, label, args))
}

func traceLine(_ arrow: String, _ label: String, _ args: [String]) -> String {
    let cut = args.map { arg in
        var text = ""
        text.unicodeScalars.append(contentsOf: arg.unicodeScalars.prefix(120))  // by code point, as 0.1.1 cut them
        return text
    }
    return "[trace] \(arrow) \(label) \(pyList(cut))"
}

/// Python's list repr, so traces keep the 0.1.1 shape: `['a', 'b']`.
public func pyList(_ items: [String]) -> String {
    "[" + items.map { escaped($0) }.joined(separator: ", ") + "]"
}

/// Single-quoted (unless `quoted` is false), with `\`, `'` and control characters escaped as Python's `repr` escaped
/// them in 0.1.1's logs: the page and MIDI devices choose these texts, and a raw newline or escape sequence in them
/// would forge log lines, as would a bidirectional control or a line separator reordering or splitting one in the
/// terminal.
public func escaped(_ text: String, quoted: Bool = true) -> String {
    var result = quoted ? "'" : ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": result += "\\\\"
        case "'": result += "\\'"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case "\u{00}"..."\u{1f}", "\u{7f}"..."\u{9f}":
            result += "\\x" + hexDigits(scalar, count: 2)
        case "\u{061C}", "\u{200E}", "\u{200F}", "\u{2028}"..."\u{202E}", "\u{2066}"..."\u{2069}", "\u{FEFF}":
            result += "\\u" + hexDigits(scalar, count: 4)
        default: result.unicodeScalars.append(scalar)
        }
    }
    return quoted ? result + "'" : result
}

/// Lowercase, zero-padded to `count` digits, as in Python's `\x1b` and `\u202e`.
private func hexDigits(_ scalar: Unicode.Scalar, count: Int) -> String {
    let hex = String(scalar.value, radix: 16)
    return String(repeating: "0", count: max(0, count - hex.count)) + hex
}
