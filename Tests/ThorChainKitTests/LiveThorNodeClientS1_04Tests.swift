import Foundation
@testable import ThorChainKit
import XCTest

final class LiveThorNodeClientS1_04Tests: XCTestCase {
    func testCancellationBeforeSendDoesNotStartTransport() async throws {
        let gate = S1_04StartGate()
        let transport = S1_04HTTPTransport(responses: [
            .json(#"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","address":"thor1x","pub_key":null,"account_number":"1","sequence":"1"}}"#, height: "12345678"),
        ])
        let testAddress = address()
        let testLease = try endpointLease()
        let operation = Task {
            await gate.wait()
            return try await LiveThorNodeClient(transport: transport).account(
                address: testAddress,
                using: testLease
            )
        }
        operation.cancel()
        await gate.open()

        do {
            _ = try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAccountRequestPreservesBasePathAndRequiresExactHeightAndBaseAccount() async throws {
        let transport = S1_04HTTPTransport(responses: [
            .json(
                #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","account_number":"29938","sequence":"607"}}"#,
                height: "12345678"
            ),
        ])
        let client = LiveThorNodeClient(
            transport: transport,
            requestTimeout: 7,
            clientId: "fixture-client",
            maximumBalancePageCount: 4
        )
        let lease = try endpointLease(basePath: "/proxy%2Fv1", height: 12_345_678)

        let account = try await client.account(address: address(), using: lease)

        XCTAssertEqual(account, AccountTransport(accountNumber: 29938, sequence: 607))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://cosmos.example/proxy%2Fv1/cosmos/auth/v1beta1/accounts/\(address().raw)"
        )
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Client-ID"), "fixture-client")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-cosmos-block-height"), "12345678")
        XCTAssertEqual(requests[0].timeoutInterval, 7)
    }

    func testAccountAcceptsOnlyExactObservedAbsenceEnvelope() async throws {
        let requestedAddress = address()
        let exactMessage = "rpc error: code = NotFound desc = account \(requestedAddress.raw) not found: key not found"
        let shortMessage = "account \(requestedAddress.raw) not found"
        let acceptedBodies = [
            #"{"code":5,"message":"\#(exactMessage)","details":[]}"#,
            #"{"code":5,"message":"\#(shortMessage)","details":[]}"#,
        ]
        for body in acceptedBodies {
            let transport = S1_04HTTPTransport(responses: [
                .status(404, body: body, height: "12345678"),
            ])
            let account = try await LiveThorNodeClient(
                transport: transport,
                maximumBalancePageCount: 4
            ).account(address: requestedAddress, using: endpointLease())
            XCTAssertNil(account)
        }

        let rejectedBodies = [
            #"{"code":5,"message":"account not found","details":[]}"#,
            #"{"code":5,"message":"\#(shortMessage) extra","details":[]}"#,
            #"{"code":5,"message":" \#(shortMessage)","details":[]}"#,
            #"{"code":5,"message":"account \#(requestedAddress.raw)  not found","details":[]}"#,
            #"{"code":5,"message":"\#(shortMessage)","details":[{}]}"#,
            #"{"code":4,"message":"\#(shortMessage)","details":[]}"#,
            #"{"code":5,"message":"account thor1foreign not found","details":[]}"#,
            #"{"code":5,"message":"\#(shortMessage)","details":[],"message":"other"}"#,
            #"{"code":5,"message":"\#(shortMessage)","details":[],"code":5}"#,
            #"{"code":5,"message":"\#(shortMessage)","details":[]"#,
        ]
        for body in rejectedBodies {
            let transport = S1_04HTTPTransport(responses: [
                .status(404, body: body, height: "12345678"),
            ])
            await XCTAssertThrowsThorNodeError(.httpStatus(operation: .account, code: 404, retryAfterSeconds: nil)) {
                try await LiveThorNodeClient(
                    transport: transport,
                    maximumBalancePageCount: 4
                ).account(address: requestedAddress, using: endpointLease())
            }
        }

        let heightMismatch = S1_04HTTPTransport(responses: [
            .status(404, body: #"{"code":5,"message":"\#(shortMessage)","details":[]}"#, height: "12345677"),
        ])
        await XCTAssertThrowsThorNodeError(.heightMismatch(expected: 12_345_678, actual: "12345677")) {
            try await LiveThorNodeClient(
                transport: heightMismatch,
                maximumBalancePageCount: 4
            ).account(address: requestedAddress, using: endpointLease())
        }

        for height in [nil, "not-a-height"] {
            let missingHeight = S1_04HTTPTransport(responses: [
                .status(404, body: #"{"code":5,"message":"\#(shortMessage)","details":[]}"#, height: height),
            ])
            await XCTAssertThrowsThorNodeError(.heightMismatch(expected: 12_345_678, actual: height)) {
                try await LiveThorNodeClient(
                    transport: missingHeight,
                    maximumBalancePageCount: 4
                ).account(address: requestedAddress, using: endpointLease())
            }
        }

        let non404 = S1_04HTTPTransport(responses: [
            .json(#"{"code":5,"message":"\#(shortMessage)","details":[]}"#, height: "12345678"),
        ])
        await XCTAssertThrowsThorNodeError(.malformedResponse(operation: .account)) {
            try await LiveThorNodeClient(
                transport: non404,
                maximumBalancePageCount: 4
            ).account(address: requestedAddress, using: endpointLease())
        }

        let balances = S1_04HTTPTransport(responses: [
            .status(404, body: #"{"code":5,"message":"\#(shortMessage)","details":[]}"#, height: "12345678"),
        ])
        await XCTAssertThrowsThorNodeError(.httpStatus(operation: .balances, code: 404, retryAfterSeconds: nil)) {
            try await LiveThorNodeClient(
                transport: balances,
                maximumBalancePageCount: 4
            ).balances(address: requestedAddress, using: endpointLease())
        }
    }

    func testAccountRejectsUnsupportedTypeOverflowAndMismatchedHeight() async throws {
        let cases: [(String, String?, ThorNodeReadError)] = [
            (
                #"{"account":{"@type":"/cosmos.vesting.v1beta1.ContinuousVestingAccount","account_number":"1","sequence":"2"}}"#,
                "12345678",
                .unsupportedAccountType
            ),
            (
                #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","account_number":"18446744073709551616","sequence":"2"}}"#,
                "12345678",
                .invalidAccount
            ),
            (
                #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","account_number":"01","sequence":"2"}}"#,
                "12345678",
                .invalidAccount
            ),
            (
                #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","account_number":"1","sequence":"+1"}}"#,
                "12345678",
                .invalidAccount
            ),
            (
                #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","account_number":"1","sequence":"2"}}"#,
                "12345677",
                .heightMismatch(expected: 12_345_678, actual: "12345677")
            ),
        ]

        for (body, height, expected) in cases {
            let transport = S1_04HTTPTransport(responses: [.json(body, height: height)])
            let client = LiveThorNodeClient(transport: transport, maximumBalancePageCount: 4)
            await XCTAssertThrowsThorNodeError(expected) {
                try await client.account(address: address(), using: endpointLease())
            }
        }
    }

    func testBalancesFollowExactPaginationIgnoreTotalAndSortDenominations() async throws {
        let transport = S1_04HTTPTransport(responses: [
            .json(
                #"{"balances":[{"denom":"zeta","amount":"7"}],"pagination":{"next_key":"opaque+/=","total":"0"}}"#,
                height: "12345678"
            ),
            .json(
                #"{"balances":[{"denom":"rune","amount":"340282366920938463463374607431768211456"}],"pagination":{"next_key":null,"total":"0"}}"#,
                height: "12345678"
            ),
        ])
        let client = LiveThorNodeClient(transport: transport, maximumBalancePageCount: 4)

        let balances = try await client.balances(address: address(), using: endpointLease())

        XCTAssertEqual(balances, try [
            BalanceTransport(denom: .rune, amountDecimal: "340282366920938463463374607431768211456"),
            BalanceTransport(denom: Denom(rawValue: "zeta"), amountDecimal: "7"),
        ])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "pagination.limit", value: "100")]
        )
        XCTAssertEqual(
            URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems,
            [
                URLQueryItem(name: "pagination.limit", value: "100"),
                URLQueryItem(name: "pagination.key", value: "opaque+/="),
            ]
        )
        XCTAssertTrue(requests.allSatisfy {
            $0.url?.path.contains("/cosmos/bank/v1beta1/balances/\(address().raw)") == true
        })
    }

    func testBalancesRejectAmountBoundarySpellingsDuplicatesCyclesAndPageLimit() async throws {
        let invalidAmounts = [
            "115792089237316195423570985008687907853269984665640564039457584007913129639936",
            "01",
            "+1",
            " 1",
            "",
            "1x",
        ]
        for amount in invalidAmounts {
            let body = #"{"balances":[{"denom":"rune","amount":"\#(amount)"}],"pagination":{"next_key":null}}"#
            let transport = S1_04HTTPTransport(responses: [.json(body, height: "12345678")])
            let client = LiveThorNodeClient(transport: transport, maximumBalancePageCount: 4)
            await XCTAssertThrowsThorNodeError(.invalidAmount) {
                try await client.balances(address: address(), using: endpointLease())
            }
        }

        let maximum = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        let maximumTransport = S1_04HTTPTransport(responses: [
            .json(
                #"{"balances":[{"denom":"rune","amount":"\#(maximum)"}],"pagination":{"next_key":null}}"#,
                height: "12345678"
            ),
        ])
        let accepted = try await LiveThorNodeClient(
            transport: maximumTransport,
            maximumBalancePageCount: 4
        ).balances(address: address(), using: endpointLease())
        XCTAssertEqual(accepted.first?.amountDecimal, maximum)

        let duplicate = S1_04HTTPTransport(responses: [
            .json(
                #"{"balances":[{"denom":"rune","amount":"1"},{"denom":"rune","amount":"2"}],"pagination":{"next_key":null}}"#,
                height: "12345678"
            ),
        ])
        await XCTAssertThrowsThorNodeError(.duplicateDenom("rune")) {
            try await LiveThorNodeClient(
                transport: duplicate,
                maximumBalancePageCount: 4
            ).balances(address: address(), using: endpointLease())
        }

        let cycle = S1_04HTTPTransport(responses: [
            .json(#"{"balances":[],"pagination":{"next_key":"again"}}"#, height: "12345678"),
            .json(#"{"balances":[],"pagination":{"next_key":"again"}}"#, height: "12345678"),
        ])
        await XCTAssertThrowsThorNodeError(.paginationCycle) {
            try await LiveThorNodeClient(
                transport: cycle,
                maximumBalancePageCount: 4
            ).balances(address: address(), using: endpointLease())
        }

        let pageLimit = S1_04HTTPTransport(responses: [
            .json(#"{"balances":[],"pagination":{"next_key":"more"}}"#, height: "12345678"),
        ])
        await XCTAssertThrowsThorNodeError(.pageLimitExceeded) {
            try await LiveThorNodeClient(
                transport: pageLimit,
                maximumBalancePageCount: 1
            ).balances(address: address(), using: endpointLease())
        }
    }

    func testBalancesRequirePinnedHeightOnEveryPage() async throws {
        let transport = S1_04HTTPTransport(responses: [
            .json(#"{"balances":[],"pagination":{"next_key":"next"}}"#, height: "12345678"),
            .json(#"{"balances":[],"pagination":{"next_key":null}}"#, height: nil),
        ])
        await XCTAssertThrowsThorNodeError(.heightMismatch(expected: 12_345_678, actual: nil)) {
            try await LiveThorNodeClient(
                transport: transport,
                maximumBalancePageCount: 4
            ).balances(address: address(), using: endpointLease())
        }
    }

    private func address() -> Address {
        try! Address("thor166aczv0jatlnyzz8zsczdzk9xxxgppfpu530jl", network: .mainnet)
    }

    private func endpointLease(basePath: String = "", height: Int64 = 12_345_678) throws -> EndpointLease {
        try EndpointLease(
            family: EndpointFamilyDescriptor(
                id: "fixture-primary",
                cosmosRestURL: URL(string: "https://cosmos.example\(basePath)")!,
                cometBftURL: URL(string: "https://comet.example/rpc")!
            ),
            verifiedChainId: "thorchain-1",
            cosmosReadHeight: height,
            cometReferenceHeight: height + 1,
            poolGeneration: 0
        )
    }
}

private actor S1_04StartGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private actor S1_04HTTPTransport: IHttpTransport {
    enum Response: Sendable {
        case json(String, height: String?)
        case status(Int, body: String, height: String? = nil, retryAfter: String? = nil)
    }

    private var responses: [Response]
    private(set) var requests = [URLRequest]()

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard responses.isEmpty == false else { throw URLError(.resourceUnavailable) }
        let response = responses.removeFirst()
        let status: Int
        let body: String
        var headers = [String: String]()
        switch response {
        case let .json(value, height):
            status = 200
            body = value
            if let height { headers["Grpc-Metadata-X-Cosmos-Block-Height"] = height }
        case let .status(code, value, height, retryAfter):
            status = code
            body = value
            if let height { headers["Grpc-Metadata-X-Cosmos-Block-Height"] = height }
            if let retryAfter { headers["Retry-After"] = retryAfter }
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
        )
    }
}

private func XCTAssertThrowsThorNodeError<T>(
    _ expected: ThorNodeReadError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as ThorNodeReadError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
