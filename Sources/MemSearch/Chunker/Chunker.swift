import Foundation

/// Heading-split markdown chunker. Mirrors `src/memsearch/chunker.py` byte-for-byte
/// for the Phase 1 cross-check (success criterion 6). The golden fixture in
/// `Tests/MemSearchTests/Fixtures/chunker-{input.md,expected.json}` anchors parity.
public enum Chunker {

    public static func chunk(
        text: String,
        source: URL,
        policy: ChunkingPolicy = .default,
        embedderModelName: String
    ) -> [Chunk] {
        let lines = text.components(separatedBy: "\n")
        let headings = findHeadings(in: lines)
        let sections = buildSections(lines: lines, headings: headings)

        var chunks: [Chunk] = []
        for s in sections {
            let sectionText = lines[s.start..<s.end]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sectionText.isEmpty, hasMeaningfulContent(sectionText) else { continue }

            if codepointCount(sectionText) <= policy.maxChunkSize {
                let startLine = s.start + 1
                let endLine = s.end
                chunks.append(makeChunk(
                    content: sectionText,
                    source: source,
                    heading: s.heading,
                    headingLevel: s.level,
                    startLine: startLine,
                    endLine: endLine,
                    embedderModelName: embedderModelName
                ))
            } else {
                let split = splitLargeSection(
                    lines: Array(lines[s.start..<s.end]),
                    source: source,
                    heading: s.heading,
                    headingLevel: s.level,
                    baseLine: s.start,
                    maxSize: policy.maxChunkSize,
                    overlap: policy.overlapLines,
                    embedderModelName: embedderModelName
                )
                chunks.append(contentsOf: split)
            }
        }
        return chunks
    }

    // MARK: - Heading detection / section build

    private struct Heading {
        let lineIdx: Int
        let level: Int
        let title: String
    }

    private struct Section {
        let start: Int
        let end: Int
        let heading: String
        let level: Int
    }

    /// Mirrors Python `^(#{1,6})\s+(.+)$` (re.MULTILINE).
    /// In Python's `re.match`, `\s+` allows any whitespace; here we mirror that.
    private static func findHeadings(in lines: [String]) -> [Heading] {
        var out: [Heading] = []
        let scalarSpace = Set<Character>([" ", "\t"])
        for (i, line) in lines.enumerated() {
            // Count leading '#' characters (1..=6).
            var level = 0
            for ch in line {
                if ch == "#" { level += 1 } else { break }
            }
            guard level >= 1, level <= 6 else { continue }
            // Must be followed by at least one whitespace then non-empty title.
            let afterHashes = line.index(line.startIndex, offsetBy: level)
            guard afterHashes < line.endIndex, scalarSpace.contains(line[afterHashes]) else { continue }
            // Skip whitespace; ensure there's a non-empty trailing title.
            var titleStart = afterHashes
            while titleStart < line.endIndex, scalarSpace.contains(line[titleStart]) {
                titleStart = line.index(after: titleStart)
            }
            guard titleStart < line.endIndex else { continue }
            // Python `.strip()` on group(2) trims leading + trailing whitespace.
            let title = line[titleStart...].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            out.append(Heading(lineIdx: i, level: level, title: title))
        }
        return out
    }

    private static func buildSections(lines: [String], headings: [Heading]) -> [Section] {
        var out: [Section] = []
        if headings.isEmpty || headings[0].lineIdx > 0 {
            let end = headings.first?.lineIdx ?? lines.count
            out.append(Section(start: 0, end: end, heading: "", level: 0))
        }
        for (i, h) in headings.enumerated() {
            let next = (i + 1 < headings.count) ? headings[i + 1].lineIdx : lines.count
            out.append(Section(start: h.lineIdx, end: next, heading: h.title, level: h.level))
        }
        return out
    }

    /// Mirrors `_has_meaningful_content`: strip HTML comments + heading lines,
    /// then check the remaining body has ≥ 2 chars after `.strip()`.
    private static func hasMeaningfulContent(_ text: String) -> Bool {
        // Python uses re.DOTALL on `<!--.*?-->`; Swift's NSRegularExpression
        // requires `(?s)` to make `.` match newlines.
        let stripped = text.replacingOccurrences(
            of: "(?s)<!--.*?-->",
            with: "",
            options: .regularExpression
        )
        let body = stripped
            .components(separatedBy: "\n")
            .filter { !isHeadingLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return codepointCount(body) >= 2
    }

    /// Mirrors `_HEADING_RE.match`: a line starts a heading iff `^#{1,6}\s+(.+)`.
    private static func isHeadingLine(_ line: String) -> Bool {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return false }
        let afterHashes = line.index(line.startIndex, offsetBy: level)
        guard afterHashes < line.endIndex else { return false }
        let next = line[afterHashes]
        guard next == " " || next == "\t" else { return false }
        // Must have at least one non-whitespace char after the whitespace run.
        var idx = line.index(after: afterHashes)
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
        }
        return idx < line.endIndex
    }

    private static func makeChunk(
        content: String,
        source: URL,
        heading: String,
        headingLevel: Int,
        startLine: Int,
        endLine: Int,
        embedderModelName: String
    ) -> Chunk {
        let contentHash = ChunkID.contentHash(for: content)
        let id = ChunkID.compute(
            source: source.lastPathComponent,
            startLine: startLine,
            endLine: endLine,
            contentHash: contentHash,
            model: embedderModelName
        )
        return Chunk(
            id: id,
            source: source,
            heading: heading,
            headingLevel: headingLevel,
            startLine: startLine,
            endLine: endLine,
            content: content,
            contentHash: contentHash
        )
    }

    // MARK: - Large-section splitter (mirrors `_split_large_section`)

    private static func splitLargeSection(
        lines sectionLines: [String],
        source: URL,
        heading: String,
        headingLevel: Int,
        baseLine: Int,
        maxSize: Int,
        overlap: Int,
        embedderModelName: String
    ) -> [Chunk] {
        var chunks: [Chunk] = []
        var currentLines: [String] = []
        var currentStart = 0

        // Emit a chunk verbatim (already trimmed by the caller in `_emit_bounded`).
        func emit(_ content: String, _ startLine: Int, _ endLine: Int) {
            guard !content.isEmpty else { return }
            chunks.append(makeChunk(
                content: content,
                source: source,
                heading: heading,
                headingLevel: headingLevel,
                startLine: startLine,
                endLine: endLine,
                embedderModelName: embedderModelName
            ))
        }

        // Trim, intra-line split if still too big, then emit.
        func emitBounded(_ raw: String, _ startLine: Int, _ endLine: Int) {
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }
            if codepointCount(content) > maxSize {
                for part in splitLongText(content, maxSize: maxSize) {
                    emit(part.trimmingCharacters(in: .whitespacesAndNewlines), startLine, endLine)
                }
            } else {
                emit(content, startLine, endLine)
            }
        }

        for i in 0..<sectionLines.count {
            let line = sectionLines[i]
            currentLines.append(line)
            let text = currentLines.joined(separator: "\n")

            let isParagraphBreak = line.trimmingCharacters(in: .whitespaces).isEmpty
                && (i + 1 < sectionLines.count)
            let isLastLine = (i == sectionLines.count - 1)
            let textLen = codepointCount(text)

            // Preferred: split at paragraph boundary.
            if textLen >= maxSize, isParagraphBreak {
                emitBounded(text, baseLine + currentStart + 1, baseLine + i + 1)
                let overlapStart = max(0, currentLines.count - overlap)
                currentLines = Array(currentLines[overlapStart...])
                currentStart = i + 1 - currentLines.count
                continue
            }

            // Forced line-boundary split with rollback.
            if textLen >= maxSize, !isParagraphBreak, currentLines.count > 1 {
                currentLines.removeLast()
                let content = currentLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                emitBounded(content, baseLine + currentStart + 1, baseLine + i)
                let overlapStart = max(0, currentLines.count - overlap)
                currentLines = Array(currentLines[overlapStart...])
                currentLines.append(line) // re-add the rolled-back line
                currentStart = i - currentLines.count + 1
                continue
            }

            // Single line exceeds maxSize — split within the line.
            if textLen >= maxSize, currentLines.count == 1 {
                let subChunks = splitLongText(text, maxSize: maxSize)
                for part in subChunks {
                    emit(part.trimmingCharacters(in: .whitespacesAndNewlines),
                         baseLine + currentStart + 1, baseLine + i + 1)
                }
                currentLines = []
                currentStart = i + 1
                continue
            }

            if isLastLine {
                emitBounded(text, baseLine + currentStart + 1, baseLine + i + 1)
                currentLines = []
            }
        }

        // Flush any remaining content (e.g., a rolled-back line on the last
        // iteration that didn't get a chance to be emitted).
        if !currentLines.isEmpty {
            let remaining = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                let endLine = baseLine + sectionLines.count
                let startLine = baseLine + currentStart + 1
                emitBounded(remaining, startLine, endLine)
            }
        }

        return chunks
    }

    // MARK: - Sentence-ending splitter (mirrors `_split_long_text`)

    /// Mirrors Python `_SENTENCE_END_RE`:
    /// `(?:……|…|[。！？；]\s*|[.!?;](?=\s|$|[CJK])\s*)`
    /// (CJK ranges: 4E00-9FFF, 3040-30FF, AC00-D7AF.)
    ///
    /// Note: We embed the literal Unicode characters (via Swift `\u{...}`)
    /// rather than ICU `\uHHHH` escapes — keeps the pattern readable and
    /// avoids the trap that raw-string `#"..."#` does *not* expand `\u{...}`.
    private static let sentenceEndRegex: NSRegularExpression = {
        let pattern =
            "(?:\u{2026}\u{2026}|\u{2026}" +
            "|[\u{3002}\u{FF01}\u{FF1F}\u{FF1B}]\\s*" +
            "|[\\.!?;](?=\\s|$|[\u{4E00}-\u{9FFF}\u{3040}-\u{30FF}\u{AC00}-\u{D7AF}])\\s*)"
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Split a long string ≤ maxSize, preferring sentence boundaries.
    /// Indices are UTF-16 (NSRegularExpression's native unit) and we round-trip
    /// through `String.UTF16View`. Matches Python's codepoint-based slicing for
    /// BMP-only content (the chunker is markdown text — the cases that matter).
    private static func splitLongText(_ text: String, maxSize: Int) -> [String] {
        var parts: [String] = []
        var remaining = text
        while codepointCount(remaining) > maxSize {
            // Look for the last sentence boundary within the first `maxSize` codepoints.
            let prefix = codepointPrefix(remaining, maxSize)
            let nsPrefix = prefix as NSString
            let range = NSRange(location: 0, length: nsPrefix.length)
            var bestEnd = -1   // codepoint offset (Python semantics)
            sentenceEndRegex.enumerateMatches(in: prefix, range: range) { match, _, _ in
                if let m = match {
                    // Convert UTF-16 end → codepoint offset within `prefix`.
                    let utf16End = m.range.upperBound
                    let strIdx = String.Index(utf16Offset: utf16End, in: prefix)
                    bestEnd = prefix.unicodeScalars.distance(
                        from: prefix.unicodeScalars.startIndex,
                        to: strIdx.samePosition(in: prefix.unicodeScalars) ?? prefix.unicodeScalars.endIndex
                    )
                }
            }
            if bestEnd > 0 {
                let head = codepointPrefix(remaining, bestEnd)
                parts.append(head)
                remaining = codepointSuffix(remaining, bestEnd)
            } else {
                // Hard split at maxSize codepoints.
                let head = codepointPrefix(remaining, maxSize)
                parts.append(head)
                remaining = codepointSuffix(remaining, maxSize)
            }
        }
        if !remaining.isEmpty {
            parts.append(remaining)
        }
        return parts
    }

    // MARK: - Codepoint helpers (Python `len(str)` / slicing semantics)

    /// Python `len(s)` — counts unicode scalars (codepoints).
    private static func codepointCount(_ s: String) -> Int {
        return s.unicodeScalars.count
    }

    /// `s[:n]` in Python codepoint semantics.
    private static func codepointPrefix(_ s: String, _ n: Int) -> String {
        let scalars = s.unicodeScalars
        guard n < scalars.count else { return s }
        if n <= 0 { return "" }
        let end = scalars.index(scalars.startIndex, offsetBy: n)
        return String(String.UnicodeScalarView(scalars[scalars.startIndex..<end]))
    }

    /// `s[n:]` in Python codepoint semantics.
    private static func codepointSuffix(_ s: String, _ n: Int) -> String {
        let scalars = s.unicodeScalars
        guard n < scalars.count else { return "" }
        if n <= 0 { return s }
        let start = scalars.index(scalars.startIndex, offsetBy: n)
        return String(String.UnicodeScalarView(scalars[start..<scalars.endIndex]))
    }
}
