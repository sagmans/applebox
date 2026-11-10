import Foundation

/// Keeps clipboard search per keystroke proportional to the query, not to the size of the history.
///
/// Folding a clip for fuzzy matching costs far more than matching it: non-ASCII text folds one
/// character at a time, so 50 clips of 64 KiB took about half a second per keystroke. The fold depends
/// only on the clip, so it is built once per clip and kept while the clip stays in history. A query
/// that extends the previous one can only match clips the previous one matched, so it searches those
/// alone, as app search does in `SearchService`.
///
/// Searches run off the main actor and a superseded one may still be unwinding while its replacement
/// starts, so the caches are only touched inside `lock`. `@unchecked Sendable` relies on that.
final nonisolated class ClipSearchIndex: @unchecked Sendable {
    typealias Match = ClipboardManager.ClipboardSearchMatch

    /// Upper bound for cached folds. Normal histories fit well inside it (50 non-ASCII clips of 64 KiB
    /// take about 5.5 MB), but any app can write the pasteboard, so clips crafted to defeat the compact
    /// form must not grow the launcher without limit. Clips past the budget are folded per search,
    /// which is slower but still correct.
    private static let foldCacheByteBudget = 16 * 1024 * 1024

    /// The result set a refinement may narrow. Bound to the exact history it came from, because an
    /// added, removed, or expired clip changes which clips are candidates even for the same query.
    private struct Refinement {
        let query: FuzzyText
        let historyIDs: [UUID]
        let matchedIDs: Set<UUID>
    }

    private let lock = NSLock()
    /// Eviction runs here so history changes, which are often on the main actor, never wait for a
    /// search that holds `lock`. Same priority as searches, because a search on the main actor can
    /// wait on `lock` while an eviction holds it.
    private let evictionQueue = DispatchQueue(label: "applebox.clipboard.search-eviction", qos: .userInitiated)
    /// Keyed by clip identity, not content, so a repeated copy that leaves history frees its entry.
    private var folded: [UUID: ClipFold] = [:]
    private var foldedBytes = 0
    private var refinement: Refinement?

    /// Ranks `history` (most recent first) against a non-empty, trimmed query.
    ///
    /// Returns an empty list once `isCancelled` reports true; the caller discards a cancelled search,
    /// so partial work is never published. Folds built before the cancellation stay cached, so the
    /// next keystroke does not pay for them again. Cancellation is checked between clips, so a caller
    /// on the main actor waits at most for one clip's fold of a superseded search.
    func search(_ trimmedQuery: String, in history: [ClipboardItem], isCancelled: () -> Bool) -> [Match] {
        lock.withLock { searchLocked(trimmedQuery, in: history, isCancelled: isCancelled) }
    }

    /// Frees the folds of clips that left history as soon as history changes, so a removed clip's text
    /// does not linger in memory until the next clipboard search. `currentHistory` is read when the
    /// eviction runs, not when it is queued: changes come from several threads, and a snapshot taken
    /// earlier could run last and keep a removed clip.
    func historyDidChange(_ currentHistory: @escaping @Sendable () -> [ClipboardItem]) {
        evictionQueue.async { [self] in
            let ids = Set(currentHistory().map(\.id))
            lock.withLock { evict(keeping: ids) }
        }
    }

    private func searchLocked(_ trimmedQuery: String, in history: [ClipboardItem], isCancelled: () -> Bool) -> [Match] {
        let historyIDs = history.map(\.id)
        evict(keeping: Set(historyIDs))
        guard !isCancelled() else { return [] }

        let query = FuzzyText(trimmedQuery)
        let queryCharacters = query.characters
        let narrowedTo: Set<UUID>? = if let refinement, refinement.historyIDs == historyIDs, query.hasPrefix(refinement.query) {
            refinement.matchedIDs
        } else {
            nil
        }

        // History order is the tie-breaker, so each candidate keeps its position in the full history
        // even when the search is narrowed.
        var scored: [(index: Int, match: Match)] = []
        for (index, item) in history.enumerated() {
            if let narrowedTo, !narrowedTo.contains(item.id) {
                continue
            }
            guard !isCancelled() else { return [] }
            let result = foldedText(for: item).match(query, characters: queryCharacters)
            guard result.score > 0 else { continue }
            scored.append((index, Match(item: item, score: result.score, matchedIndices: result.matchedIndices)))
        }
        guard !isCancelled() else { return [] }

        scored.sort {
            if $0.match.score != $1.match.score {
                return $0.match.score > $1.match.score
            }
            return $0.index < $1.index
        }
        // Stored only after a full pass: a cancelled search saw a subset and must not narrow the next one.
        refinement = Refinement(query: query, historyIDs: historyIDs, matchedIDs: Set(scored.map(\.match.item.id)))
        return scored.map(\.match)
    }

    private func foldedText(for item: ClipboardItem) -> ClipFold {
        if let cached = folded[item.id] {
            return cached
        }
        let fold = ClipFold(item.content)
        if foldedBytes + fold.estimatedBytes <= Self.foldCacheByteBudget {
            folded[item.id] = fold
            foldedBytes += fold.estimatedBytes
        }
        return fold
    }

    private func evict(keeping ids: Set<UUID>) {
        guard folded.keys.contains(where: { !ids.contains($0) }) else { return }
        folded = folded.filter { ids.contains($0.key) }
        foldedBytes = folded.values.reduce(0) { $0 + $1.estimatedBytes }
        // The history check would reject a refinement over removed clips anyway; dropping it here
        // releases it early.
        refinement = nil
    }
}

/// A clip's folded text in the form kept between searches.
///
/// `FuzzyText.unicode` stores a 16-byte `Character` and an 8-byte offset per folded character, which is
/// 24 times the size of mostly-ASCII text and too much to keep for a whole history. A clip uses only a
/// few distinct characters, so each one is stored as a 2-byte code into a per-clip table, and the
/// offsets are dropped when every original character folds to exactly one character. This lives here
/// rather than as a `FuzzyText` case because app search folds short names once per index and gains
/// nothing from it.
private nonisolated enum ClipFold: Sendable {
    /// The matcher's own form: ASCII text (already one byte per character), or non-ASCII text that
    /// does not fit the compact form.
    case full(FuzzyText)
    case interned(InternedFold)

    /// Memory cost of a `Character` in `FuzzyText.unicode` plus its `Int` source offset.
    private static let unicodeBytesPerCharacter = MemoryLayout<Character>.stride + MemoryLayout<Int>.stride

    init(_ text: String) {
        let full = FuzzyText(text)
        guard case let .unicode(characters, offsets) = full, let interned = InternedFold(characters, offsets: offsets) else {
            self = .full(full)
            return
        }
        self = .interned(interned)
    }

    /// Approximate heap size, used only to bound the cache.
    var estimatedBytes: Int {
        switch self {
        case let .full(.ascii(bytes)): bytes.count
        case let .full(.unicode(characters, _)): characters.count * Self.unicodeBytesPerCharacter
        case let .interned(fold): fold.estimatedBytes
        }
    }

    /// `queryCharacters` is `query.characters`, computed once per search instead of once per clip.
    func match(_ query: FuzzyText, characters queryCharacters: ContiguousArray<Character>) -> FuzzyMatchResult {
        switch self {
        case let .full(text): FuzzyMatcher.matchWithIndices(query: query, candidate: text)
        case let .interned(fold): fold.match(queryCharacters)
        }
    }
}

/// Folded characters as codes into a per-clip table. The table is keyed by `Character`, so two
/// characters get the same code exactly when they are equal, and scores and highlights match those of
/// the characters themselves.
private nonisolated struct InternedFold: Sendable {
    private typealias Code = UInt16
    private typealias Offset = UInt32

    /// Rough per-entry cost of the character table, used only for the cache budget.
    private static let tableEntryBytes = MemoryLayout<Character>.stride + MemoryLayout<Code>.stride

    private let codes: ContiguousArray<Code>
    private let codeOf: [Character: Code]
    /// At most one code per boundary character, so a linear scan beats hashing in the match loop.
    private let boundaryCodes: [Code]
    /// Original character position of each folded character; nil when it equals the folded position.
    private let sourceOffsets: ContiguousArray<Offset>?

    /// Fails when the clip has more distinct characters or characters than the compact types hold, so
    /// the caller keeps the full form instead of matching a truncated one.
    init?(_ characters: ContiguousArray<Character>, offsets: ContiguousArray<Int>) {
        guard characters.count <= Int(Offset.max), (offsets.last ?? 0) <= Int(Offset.max) else { return nil }
        var table: [Character: Code] = [:]
        var codes = ContiguousArray<Code>()
        codes.reserveCapacity(characters.count)
        for character in characters {
            if let code = table[character] {
                codes.append(code)
                continue
            }
            guard table.count <= Int(Code.max) else { return nil }
            let code = Code(table.count)
            table[character] = code
            codes.append(code)
        }
        self.codes = codes
        codeOf = table
        boundaryCodes = FuzzyMatcher.unicodeWordBoundaries.compactMap { table[$0] }
        sourceOffsets = offsets.indices.elementsEqual(offsets) ? nil : ContiguousArray(offsets.map { Offset($0) })
    }

    var estimatedBytes: Int {
        codes.count * MemoryLayout<Code>.stride
            + (sourceOffsets?.count ?? 0) * MemoryLayout<Offset>.stride
            + codeOf.count * Self.tableEntryBytes
    }

    func match(_ queryCharacters: ContiguousArray<Character>) -> FuzzyMatchResult {
        // Each clip has its own table, so the query is re-encoded per clip; it is a few characters long.
        var query = ContiguousArray<Code>()
        query.reserveCapacity(queryCharacters.count)
        for character in queryCharacters {
            // A character the clip never contains cannot be part of a match.
            guard let code = codeOf[character] else { return FuzzyMatchResult(score: 0, matchedIndices: []) }
            query.append(code)
        }
        let match = FuzzyMatcher.matchUnits(query: query, candidate: codes, normalize: { $0 }, isBoundary: boundaryCodes.contains)
        guard let sourceOffsets else { return match }
        return FuzzyMatchResult(score: match.score, matchedIndices: FuzzyMatcher.originalIndices(match.matchedIndices, offsets: sourceOffsets))
    }
}
