import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL verify-s1-01-xunit: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: verify-s1-01-xunit.swift <xunit> <transcript> <allowlist>")
}

let xunitPath = CommandLine.arguments[1]
let transcriptPath = CommandLine.arguments[2]
let allowlistPath = CommandLine.arguments[3]
guard let allowlistText = try? String(contentsOfFile: allowlistPath, encoding: .utf8),
      let transcript = try? String(contentsOfFile: transcriptPath, encoding: .utf8),
      let xunit = FileManager.default.contents(atPath: xunitPath)
else {
    fail("one or more inputs are unavailable")
}

let expected = Set(allowlistText.split(separator: "\n").map(String.init))
guard expected.count == 18 else {
    fail("allowlist must contain exactly 18 unique tests")
}

final class ReportParser: NSObject, XMLParserDelegate {
    var suiteCount: Int?
    var suiteFailures: Int?
    var suiteErrors: Int?
    var suiteSkipped: Int?
    var cases: [String] = []
    var caseHasFailure = false

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "testsuite" {
            suiteCount = attributeDict["tests"].flatMap(Int.init)
            suiteFailures = attributeDict["failures"].flatMap(Int.init)
            suiteErrors = attributeDict["errors"].flatMap(Int.init)
            suiteSkipped = attributeDict["skipped"].flatMap(Int.init) ?? 0
        } else if elementName == "testcase" {
            guard attributeDict["classname"] == "ThorChainKitTests.PublicApiTests",
                  let name = attributeDict["name"]
            else {
                caseHasFailure = true
                return
            }
            cases.append("ThorChainKitTests.PublicApiTests/\(name)")
        } else if elementName == "failure" || elementName == "error" || elementName == "skipped" {
            caseHasFailure = true
        }
    }
}

let delegate = ReportParser()
let parser = XMLParser(data: xunit)
parser.delegate = delegate
guard parser.parse(), !delegate.caseHasFailure,
      delegate.suiteCount == 18,
      delegate.suiteFailures == 0,
      delegate.suiteErrors == 0,
      delegate.suiteSkipped == 0,
      delegate.cases.count == 18,
      Set(delegate.cases) == expected
else {
    fail("xUnit does not contain exactly 18 passing, unskipped allowlisted cases")
}

let statusPattern = #"Test Case '-\[ThorChainKitTests\.PublicApiTests ([^\]]+)\]' (passed|failed|skipped)"#
let regex = try! NSRegularExpression(pattern: statusPattern)
let range = NSRange(transcript.startIndex..., in: transcript)
var statuses: [String: [String]] = [:]
for match in regex.matches(in: transcript, range: range) {
    let name = String(transcript[Range(match.range(at: 1), in: transcript)!])
    let status = String(transcript[Range(match.range(at: 2), in: transcript)!])
    statuses["ThorChainKitTests.PublicApiTests/\(name)", default: []].append(status)
}

guard statuses.keys.allSatisfy(expected.contains),
      expected.allSatisfy({ statuses[$0] == ["passed"] })
else {
    fail("transcript must contain exactly one terminal passed status per allowlisted case")
}

print("PASS verify-s1-01-xunit")
