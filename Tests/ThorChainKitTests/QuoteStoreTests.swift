import Foundation
import XCTest
@testable import ThorChainKit

final class QuoteStoreTests: XCTestCase {
    func testWallClockExpiryMatchesTheMonotonicDeadline() throws {
        // Two clocks describe the same lifetime: the monotonic one gates consume(), the
        // wall clock becomes quote.expiresAt and is the only barrier before broadcast.
        // Nothing else ties them together, so a change to one must change the other.
        let issuedAt = Date()
        let quote = try QuoteStore(clock: TestSendClock()).issue(
            sender: try sendTestAddress(),
            recipient: try sendOtherAddress(),
            amountMagnitude: SendMagnitude(3).data,
            nativeFeeMagnitude: SendMagnitude(1).data,
            totalDebitMagnitude: SendMagnitude(4).data,
            memo: nil,
            acceptedHeight: 12,
            generation: 1
        )

        XCTAssertEqual(quote.expiresAt.timeIntervalSince(issuedAt), 120, accuracy: 2)
    }

    func testConsumeIsAtomicAndOneUse() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)
        let quote = try issueTestQuote(in: store, clock: clock)

        XCTAssertNoThrow(try store.consume(quote, activeGeneration: 7))
        XCTAssertThrowsError(try store.consume(quote, activeGeneration: 7)) { error in
            XCTAssertEqual(error as? SendError, .quoteAlreadyConsumed)
        }
    }

    func testConcurrentConsumeHasOneWinner() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)
        let quote = try issueTestQuote(in: store, clock: clock)
        let results = ConcurrentQuoteResults()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let result = Result { try store.consume(quote, activeGeneration: 7) }
            results.append(result)
        }

        XCTAssertEqual(results.values.compactMap { try? $0.get() }.count, 1)
        XCTAssertEqual(
            results.values.compactMap { result -> SendError? in
                guard case let .failure(error) = result else { return nil }
                return error as? SendError
            }.filter { $0 == .quoteAlreadyConsumed }.count,
            31
        )
    }

    func testExpiryUsesTheQuoteLifetimeAsAnExclusiveBoundary() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)
        let quote = try issueTestQuote(in: store, clock: clock)

        clock.now += 119_999_999_999
        XCTAssertNoThrow(try store.consume(quote, activeGeneration: 7))

        let second = try issueTestQuote(in: store, clock: clock, generation: 8)
        clock.now += 120_000_000_000
        XCTAssertThrowsError(try store.consume(second, activeGeneration: 8)) { error in
            XCTAssertEqual(error as? SendError, .quoteExpired)
        }
    }

    func testAuthorityAndGenerationArePerStoreAndPerLifecycle() throws {
        let clock = TestSendClock()
        let first = QuoteStore(clock: clock)
        let second = QuoteStore(clock: clock)
        let quote = try issueTestQuote(in: first, clock: clock)

        XCTAssertThrowsError(try second.consume(quote, activeGeneration: 7)) { error in
            XCTAssertEqual(error as? SendError, .quoteOwnershipMismatch)
        }
        XCTAssertThrowsError(try first.consume(quote, activeGeneration: 8)) { error in
            XCTAssertEqual(error as? SendError, .quoteGenerationInvalidated)
        }
    }

    func testIssueRejectsUncheckedTotalDebit() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)

        XCTAssertThrowsError(
            try store.issue(
                sender: try sendTestAddress(),
                recipient: try sendTestAddress(),
                amountMagnitude: SendMagnitude(3).data,
                nativeFeeMagnitude: SendMagnitude(2).data,
                totalDebitMagnitude: SendMagnitude(4).data,
                memo: nil,
                acceptedHeight: 12,
                generation: 9
            )
        ) { error in
            XCTAssertEqual(error as? SendError, .operationUnavailable)
        }
    }

    func testIssueRejectsLeadingZeroZeroAndMismatchedMagnitudes() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)
        let sender = try sendTestAddress()
        let recipient = try sendOtherAddress()

        let cases: [(Data, Data, Data)] = [
            (Data([0, 3]), SendMagnitude(2).data, SendMagnitude(5).data),
            (Data(), SendMagnitude(2).data, SendMagnitude(2).data),
            (SendMagnitude(3).data, Data([0]), SendMagnitude(3).data),
            (SendMagnitude(3).data, SendMagnitude(2).data, Data([0, 5])),
            (SendMagnitude(3).data, SendMagnitude(2).data, Data()),
            (SendMagnitude(3).data, SendMagnitude(2).data, SendMagnitude(4).data)
        ]
        for (amount, fee, totalDebit) in cases {
            XCTAssertThrowsError(
                try store.issue(
                    sender: sender,
                    recipient: recipient,
                    amountMagnitude: amount,
                    nativeFeeMagnitude: fee,
                    totalDebitMagnitude: totalDebit,
                    memo: nil,
                    acceptedHeight: 12,
                    generation: 9
                )
            ) { error in
                XCTAssertEqual(error as? SendError, .operationUnavailable)
            }
        }
    }

    func testIssueRejectsMissingProviderFamilyLeaseIdentity() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)

        XCTAssertThrowsError(
            try store.issue(
                sender: try sendTestAddress(),
                recipient: try sendOtherAddress(),
                amountMagnitude: SendMagnitude(3).data,
                nativeFeeMagnitude: SendMagnitude(2).data,
                totalDebitMagnitude: SendMagnitude(5).data,
                memo: nil,
                acceptedHeight: 12,
                generation: 9,
                providerFamilyID: ""
            )
        ) { error in
            XCTAssertEqual(error as? SendError, .operationUnavailable)
        }
    }

    func testQuoteProjectionChecksReviewSenderAndExactExpiry() throws {
        let clock = TestSendClock()
        let source = QuoteStore(clock: clock)
        let quote = try issueTestQuote(in: source, clock: clock, generation: 12)
        let projection = SendQuote(
            recipient: quote.recipient,
            amountMagnitude: SendMagnitude(100).data,
            nativeFeeMagnitude: SendMagnitude(2).data,
            totalDebitMagnitude: SendMagnitude(102).data,
            memo: quote.memo,
            acceptedHeight: quote.acceptedHeight,
            expiresAt: Date(timeIntervalSince1970: 99),
            authorityRecord: quote.internalAuthorityRecord,
            sender: try sendOtherAddress().raw
        )

        XCTAssertFalse(projection.hasConsistentAuthorityProjection)
    }

    func testQuoteProjectionBindsPreflightContextDigest() throws {
        let snapshot = try SendSnapshot.fixture(height: 12)
        let store = QuoteStore()
        let quote = try store.issue(
            sender: try Address(snapshot.sender, network: .mainnet), recipient: try Address(snapshot.recipient, network: .mainnet),
            amountMagnitude: SendMagnitude(snapshot.amount).data, nativeFeeMagnitude: SendMagnitude(snapshot.nativeFee).data, totalDebitMagnitude: SendMagnitude(snapshot.totalDebit).data,
            memo: nil, acceptedHeight: snapshot.height, generation: 7, providerFamilyID: snapshot.familyID, preflightContext: snapshot
        )
        let record = quote.internalAuthorityRecord
        let invalidSnapshot = QuoteReviewSnapshot(
            sender: record.snapshot.sender, recipient: record.snapshot.recipient,
            amountMagnitude: record.snapshot.amountMagnitude, nativeFeeMagnitude: record.snapshot.nativeFeeMagnitude,
            totalDebitMagnitude: record.snapshot.totalDebitMagnitude, memo: record.snapshot.memo,
            acceptedHeight: record.snapshot.acceptedHeight, expiresAt: record.snapshot.expiresAt,
            accountNumber: record.snapshot.accountNumber, sequence: record.snapshot.sequence,
            providerFamilyID: record.snapshot.providerFamilyID, preflightContext: snapshot,
            preflightDigest: Data(repeating: 0, count: 32)
        )
        let invalid = SendQuote(
            recipient: quote.recipient, amountMagnitude: record.snapshot.amountMagnitude, nativeFeeMagnitude: record.snapshot.nativeFeeMagnitude, totalDebitMagnitude: record.snapshot.totalDebitMagnitude,
            memo: quote.memo, acceptedHeight: quote.acceptedHeight, expiresAt: quote.expiresAt,
            authorityRecord: QuoteAuthorityRecord(envelope: record.envelope, snapshot: invalidSnapshot), sender: snapshot.sender
        )
        XCTAssertFalse(invalid.hasConsistentAuthorityProjection)
    }

    func testQuoteProjectionRejectsCoherentButNonCanonicalTotal() throws {
        let quote = try issueTestQuote(in: QuoteStore(), clock: TestSendClock(), generation: 12)
        let record = quote.internalAuthorityRecord
        let invalidSnapshot = QuoteReviewSnapshot(
            sender: record.snapshot.sender,
            recipient: record.snapshot.recipient,
            amountMagnitude: Data([0, 100]),
            nativeFeeMagnitude: record.snapshot.nativeFeeMagnitude,
            totalDebitMagnitude: Data([0, 102]),
            memo: record.snapshot.memo,
            acceptedHeight: record.snapshot.acceptedHeight,
            expiresAt: record.snapshot.expiresAt,
            accountNumber: record.snapshot.accountNumber,
            sequence: record.snapshot.sequence,
            providerFamilyID: record.snapshot.providerFamilyID
        )
        let invalid = SendQuote(
            recipient: quote.recipient,
            amountMagnitude: invalidSnapshot.amountMagnitude,
            nativeFeeMagnitude: invalidSnapshot.nativeFeeMagnitude,
            totalDebitMagnitude: invalidSnapshot.totalDebitMagnitude,
            memo: quote.memo,
            acceptedHeight: quote.acceptedHeight,
            expiresAt: invalidSnapshot.expiresAt,
            authorityRecord: QuoteAuthorityRecord(envelope: record.envelope, snapshot: invalidSnapshot),
            sender: invalidSnapshot.sender
        )

        XCTAssertFalse(invalid.hasConsistentAuthorityProjection)
    }

    func testQuoteProjectionRejectsInvalidMagnitudesAndCheckedTotal() throws {
        let quote = try issueTestQuote(in: QuoteStore(), clock: TestSendClock(), generation: 12)
        let record = quote.internalAuthorityRecord

        func projection(amount: Data, fee: Data, total: Data, providerFamilyID: String = "contract") -> SendQuote {
            let snapshot = QuoteReviewSnapshot(
                sender: record.snapshot.sender,
                recipient: record.snapshot.recipient,
                amountMagnitude: amount,
                nativeFeeMagnitude: fee,
                totalDebitMagnitude: total,
                memo: record.snapshot.memo,
                acceptedHeight: record.snapshot.acceptedHeight,
                expiresAt: record.snapshot.expiresAt,
                accountNumber: record.snapshot.accountNumber,
                sequence: record.snapshot.sequence,
                providerFamilyID: providerFamilyID
            )
            return SendQuote(
                recipient: quote.recipient,
                amountMagnitude: amount,
                nativeFeeMagnitude: fee,
                totalDebitMagnitude: total,
                memo: quote.memo,
                acceptedHeight: quote.acceptedHeight,
                expiresAt: snapshot.expiresAt,
                authorityRecord: QuoteAuthorityRecord(envelope: record.envelope, snapshot: snapshot),
                sender: snapshot.sender
            )
        }

        let invalidProjections = [
            projection(amount: Data([0, 100]), fee: SendMagnitude(2).data, total: SendMagnitude(102).data),
            projection(amount: Data(), fee: SendMagnitude(2).data, total: SendMagnitude(2).data),
            projection(amount: SendMagnitude(100).data, fee: Data([0]), total: SendMagnitude(100).data),
            projection(amount: SendMagnitude(100).data, fee: SendMagnitude(2).data, total: Data([0, 102])),
            projection(amount: SendMagnitude(100).data, fee: SendMagnitude(2).data, total: SendMagnitude(101).data),
            projection(amount: Data(), fee: Data(), total: Data()),
            projection(amount: SendMagnitude(100).data, fee: SendMagnitude(2).data, total: SendMagnitude(102).data, providerFamilyID: "")
        ]

        for invalid in invalidProjections {
            XCTAssertFalse(invalid.hasConsistentAuthorityProjection)
        }
    }

    func testQuoteProjectionRejectsCoherentButUnidentifiedProvider() throws {
        let quote = try issueTestQuote(in: QuoteStore(), clock: TestSendClock(), generation: 12)
        let record = quote.internalAuthorityRecord
        let invalidSnapshot = QuoteReviewSnapshot(
            sender: record.snapshot.sender,
            recipient: record.snapshot.recipient,
            amountMagnitude: record.snapshot.amountMagnitude,
            nativeFeeMagnitude: record.snapshot.nativeFeeMagnitude,
            totalDebitMagnitude: record.snapshot.totalDebitMagnitude,
            memo: record.snapshot.memo,
            acceptedHeight: record.snapshot.acceptedHeight,
            expiresAt: record.snapshot.expiresAt,
            accountNumber: record.snapshot.accountNumber,
            sequence: record.snapshot.sequence,
            providerFamilyID: ""
        )
        let invalid = SendQuote(
            recipient: quote.recipient,
            amountMagnitude: invalidSnapshot.amountMagnitude,
            nativeFeeMagnitude: invalidSnapshot.nativeFeeMagnitude,
            totalDebitMagnitude: invalidSnapshot.totalDebitMagnitude,
            memo: quote.memo,
            acceptedHeight: quote.acceptedHeight,
            expiresAt: invalidSnapshot.expiresAt,
            authorityRecord: QuoteAuthorityRecord(envelope: record.envelope, snapshot: invalidSnapshot),
            sender: invalidSnapshot.sender
        )

        XCTAssertFalse(invalid.hasConsistentAuthorityProjection)
    }

    func testInvalidationLeavesStoredQuoteUnavailable() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)
        let quote = try issueTestQuote(in: store, clock: clock, generation: 3)

        store.invalidate(generation: 3)
        XCTAssertThrowsError(try store.consume(quote, activeGeneration: 4)) { error in
            XCTAssertEqual(error as? SendError, .quoteGenerationInvalidated)
        }
    }

    func testTerminalTombstoneIsKeptThroughOriginatingDeadlineThenCleaned() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)
        let quote = try issueTestQuote(in: store, clock: clock, generation: 3)

        store.invalidate(generation: 3)
        XCTAssertFalse(store.isEmpty())
        clock.now += 119_999_999_999
        XCTAssertFalse(store.isEmpty())
        clock.now += 1
        XCTAssertTrue(store.isEmpty())
        XCTAssertThrowsError(try store.consume(quote, activeGeneration: 3)) { error in
            XCTAssertEqual(error as? SendError, .quoteExpired)
        }
    }

    func testConsumedTombstoneIsKeptThroughOriginatingDeadlineThenCleaned() throws {
        let clock = TestSendClock()
        let store = QuoteStore(clock: clock)
        let quote = try issueTestQuote(in: store, clock: clock)

        XCTAssertNoThrow(try store.consume(quote, activeGeneration: 7))
        XCTAssertFalse(store.isEmpty())
        clock.now += 120_000_000_000 - 1
        XCTAssertFalse(store.isEmpty())
        clock.now += 1
        XCTAssertTrue(store.isEmpty())
    }

    func testOwnUnexpiredMissingQuoteIsUnavailable() throws {
        let clientID = UUID()
        let clock = TestSendClock()
        let source = QuoteStore(clientID: clientID, clock: clock)
        let destination = QuoteStore(clientID: clientID, clock: clock)
        let quote = try issueTestQuote(in: source, clock: clock)

        XCTAssertThrowsError(try destination.consume(quote, activeGeneration: 7)) { error in
            XCTAssertEqual(error as? SendError, .operationUnavailable)
        }
    }
}

private final class ConcurrentQuoteResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values = [Result<QuoteAuthorityRecord, Error>]()

    func append(_ value: Result<QuoteAuthorityRecord, Error>) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
