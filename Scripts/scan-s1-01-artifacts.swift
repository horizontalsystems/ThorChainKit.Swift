import AppKit
import Foundation
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL scan-s1-01-artifacts: \(message)\n".utf8))
    exit(1)
}

func canonicalDirectory(_ path: String, label: String) -> URL {
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
        fail("\(label) is not a directory: \(path)")
    }
    return url.resolvingSymlinksInPath().standardizedFileURL
}

func isContained(_ child: URL, in parent: URL) -> Bool {
    child.path == parent.path || child.path.hasPrefix(parent.path + "/")
}

func rejectSymlinks(from root: URL, through target: URL) {
    guard isContained(target, in: root) else {
        fail("path escapes repository root: \(target.path)")
    }
    var current = root
    let relative = target.path == root.path
        ? []
        : String(target.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
    for component in relative {
        current.appendPathComponent(component)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                fail("symlink is forbidden: \(current.path)")
            }
        } catch {
            fail("cannot inspect path component \(current.path): \(error)")
        }
    }
}

let namespace = [
    "e2df225b7a00d471b1b09ec2d3344df",
    "89a11e9cfe116c05f5290683480623015",
].joined()
let secretPattern = try! NSRegularExpression(
    pattern: #"(?i)(mnemonic|seed[ _-]?phrase|private[ _-]?key|api[ _-]?key|wallet[ _-]?id|provider[ _-]?credential|(?:internal[ _-]?)?namespace)\s*[:=]\s*(?!(configuration|string)\b)[a-z0-9+/=_-]{8,}"#
)
let credentialURLPattern = try! NSRegularExpression(
    pattern: #"(?i)https?://[^/\s:]+:[^@\s]+@"#
)

func scanText(_ text: String, source: String) {
    let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
    let range = NSRange(normalized.startIndex..., in: normalized)
    guard !normalized.contains(namespace),
          secretPattern.firstMatch(in: normalized, range: range) == nil,
          credentialURLPattern.firstMatch(in: normalized, range: range) == nil
    else {
        fail("secret or internal namespace detected in \(source)")
    }
}

func readAndScan(_ url: URL) -> Data {
    do {
        let data = try Data(contentsOf: url, options: .uncached)
        if let text = String(data: data, encoding: .utf8) {
            scanText(text, source: url.path)
        }
        return data
    } catch {
        fail("cannot read \(url.path): \(error)")
    }
}

func recognizedText(in data: Data, source: URL) -> String {
    guard let image = NSImage(data: data) else {
        fail("cannot decode PNG \(source.path)")
    }
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
        fail("cannot create image representation for \(source.path)")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    do {
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
    } catch {
        fail("OCR failed for \(source.path): \(error)")
    }
    guard let observations = request.results else {
        fail("OCR returned no result collection for \(source.path)")
    }
    return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: scan-s1-01-artifacts.swift <repository-root> <artifact-root> <tracked-list>")
}

let repositoryInput = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let repositoryRoot = canonicalDirectory(repositoryInput.path, label: "repository root")
guard repositoryInput.path == repositoryRoot.path else {
    fail("repository root contains a symlink")
}

let artifactInput = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
let artifactRoot = canonicalDirectory(artifactInput.path, label: "artifact root")
guard artifactInput.path == artifactRoot.path, isContained(artifactRoot, in: repositoryRoot) else {
    fail("artifact root is symlinked or outside the repository")
}

rejectSymlinks(from: repositoryRoot, through: artifactRoot)

let trackedListURL = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
guard isContained(trackedListURL, in: artifactRoot) else {
    fail("tracked-file list is outside the artifact root")
}

rejectSymlinks(from: repositoryRoot, through: trackedListURL)
guard let trackedList = try? String(contentsOf: trackedListURL, encoding: .utf8) else {
    fail("tracked-file list is unreadable")
}

for relativePath in trackedList.split(separator: "\n").map(String.init) {
    let file = repositoryRoot.appendingPathComponent(relativePath).standardizedFileURL
    guard isContained(file, in: repositoryRoot) else {
        fail("tracked path escapes repository: \(relativePath)")
    }
    rejectSymlinks(from: repositoryRoot, through: file)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
    else {
        fail("tracked input is unavailable: \(relativePath)")
    }
    _ = readAndScan(file)
}

let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
guard let enumerator = FileManager.default.enumerator(
    at: artifactRoot,
    includingPropertiesForKeys: resourceKeys,
    options: [],
    errorHandler: { url, error in
        fail("cannot enumerate \(url.path): \(error)")
    }
) else {
    fail("cannot create artifact enumerator")
}

var pngs: [URL] = []
for case let file as URL in enumerator {
    let values: URLResourceValues
    do {
        values = try file.resourceValues(forKeys: Set(resourceKeys))
    } catch {
        fail("cannot inspect \(file.path): \(error)")
    }
    if values.isSymbolicLink == true {
        fail("symlink is forbidden: \(file.path)")
    }
    guard values.isRegularFile == true else {
        continue
    }
    let canonical = file.resolvingSymlinksInPath().standardizedFileURL
    guard isContained(canonical, in: artifactRoot), isContained(canonical, in: repositoryRoot) else {
        fail("artifact path escapes an approved root: \(file.path)")
    }
    let data = readAndScan(file)
    if file.pathExtension.lowercased() == "png" {
        pngs.append(file)
        _ = data
    }
}

guard !pngs.isEmpty else {
    fail("no PNG artifacts were enumerated")
}

var processedPNGCount = 0
for png in pngs.sorted(by: { $0.path < $1.path }) {
    let text = recognizedText(in: readAndScan(png), source: png)
    scanText(text, source: "OCR \(png.path)")
    processedPNGCount += 1
}

guard processedPNGCount == pngs.count else {
    fail("processed PNG count differs from enumeration")
}

print("PASS scan-s1-01-artifacts (\(processedPNGCount) PNG)")
