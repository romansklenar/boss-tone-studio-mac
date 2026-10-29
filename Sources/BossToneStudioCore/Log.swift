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
    "[" + items.map(escaped).joined(separator: ", ") + "]"
}

/// Single-quoted, with `\`, `'` and control characters escaped as Python's `repr` escaped them in 0.1.1's logs: the
/// page and MIDI devices choose these texts, and a raw newline or escape sequence in them would forge log lines.
public func escaped(_ text: String) -> String {
    var result = "'"
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": result += "\\\\"
        case "'": result += "\\'"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case "\u{00}"..."\u{1f}", "\u{7f}"..."\u{9f}":
            let hex = String(scalar.value, radix: 16)
            result += "\\x" + (hex.count < 2 ? "0" : "") + hex
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result + "'"
}
