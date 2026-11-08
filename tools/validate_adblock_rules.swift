// Prüft die erzeugten Regelsätze auf dem Mac mit WebKits echtem Kompilierer.
// Aufruf:
//   swiftc -O tools/validate_adblock_rules.swift -o /tmp/validate_adblock
//   /tmp/validate_adblock _Project/Browser/ContentBlocker
// Bei einem Fehler wird per Halbierung die schuldige Regel gesucht und ausgegeben.
import Foundation
import WebKit

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "_Project/Browser/ContentBlocker")
let storeURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adblock-validate-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
let store = WKContentRuleListStore(url: storeURL)!

func compile(_ id: String, _ json: String) -> (ok: Bool, seconds: Double, message: String) {
    var result: (Bool, Double, String) = (false, 0, "")
    var done = false
    let start = Date()
    store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
        result = (list != nil, Date().timeIntervalSince(start), error.map { "\($0)" } ?? "")
        done = true
    }
    while !done { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    return result
}

func findBad(_ rules: [[String: Any]], _ lo: Int, _ hi: Int, _ out: inout [Int]) {
    if hi - lo == 1 { out.append(lo); return }
    let mid = (lo + hi) / 2
    for (a, b) in [(lo, mid), (mid, hi)] {
        let slice = Array(rules[a..<b])
        let data = try! JSONSerialization.data(withJSONObject: slice)
        if !compile("bisect", String(data: data, encoding: .utf8)!).ok {
            findBad(rules, a, b, &out)
        }
    }
}

let manifestData = try! Data(contentsOf: dir.appendingPathComponent("manifest.json"))
let manifest = try! JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
var failed = false
for entry in manifest["lists"] as! [[String: Any]] {
    let name = entry["name"] as! String
    let packed = try! Data(contentsOf: dir.appendingPathComponent(entry["file"] as! String))
    let json = try! (packed as NSData).decompressed(using: .zlib) as Data
    let text = String(data: json, encoding: .utf8)!
    let r = compile(name, text)
    print(String(format: "%@: %@ %d Regeln, %.1f s %@", name, r.ok ? "OK" : "FEHLER", entry["rules"] as! Int, r.seconds, r.message))
    if !r.ok {
        failed = true
        let rules = try! JSONSerialization.jsonObject(with: json) as! [[String: Any]]
        var bad: [Int] = []
        findBad(rules, 0, rules.count, &bad)
        for i in bad.prefix(50) {
            print("  schlechte Regel \(i): \(String(data: try! JSONSerialization.data(withJSONObject: rules[i]), encoding: .utf8)!)")
        }
    }
}
try? FileManager.default.removeItem(at: storeURL)
exit(failed ? 1 : 0)
