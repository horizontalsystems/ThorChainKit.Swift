import Foundation
import XCTest
@testable import ThorChainKit

final class CosmosAccountClientTests: XCTestCase {
    private let address = "thor1x0jkvqdh2hlpeztd5zyyk70n3efx6mhudkmnn2"

    func testFetchAccountReadsBaseAccountNumbers() async throws {
        let client = makeClient(body: #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","address":"\#(address)","pub_key":null,"account_number":"42","sequence":"7"}}"#)

        let account = try await client.fetchAccount(address: address)

        XCTAssertEqual(account, SendAccountInfo(accountNumber: 42, sequence: 7))
    }

    func testFetchAccountUnwrapsVestingAndDirectlyNestedBaseAccounts() async throws {
        // Cosmos vesting accounts embed BaseVestingAccount which embeds BaseAccount.
        let vesting = makeClient(body: #"{"account":{"@type":"/cosmos.vesting.v1beta1.ContinuousVestingAccount","base_vesting_account":{"base_account":{"address":"\#(address)","account_number":"42","sequence":"7"},"end_time":"0"}}}"#)
        let vestingAccount = try await vesting.fetchAccount(address: address)
        XCTAssertEqual(vestingAccount, SendAccountInfo(accountNumber: 42, sequence: 7))

        // Eth-style accounts nest base_account directly.
        let direct = makeClient(body: #"{"account":{"@type":"/ethermint.types.v1.EthAccount","base_account":{"address":"\#(address)","account_number":"42","sequence":"7"}}}"#)
        let directAccount = try await direct.fetchAccount(address: address)
        XCTAssertEqual(directAccount, SendAccountInfo(accountNumber: 42, sequence: 7))
    }

    func testFetchAccountRejectsAModuleAccount() async {
        let client = makeClient(body: #"{"account":{"@type":"/cosmos.auth.v1beta1.ModuleAccount","base_account":{"address":"\#(address)","account_number":"42","sequence":"7"},"name":"bond"}}"#)

        do {
            _ = try await client.fetchAccount(address: address)
            XCTFail("a module account must not produce a signing account")
        } catch {
            XCTAssertEqual(error as? SendError, .accountUnavailable)
        }
    }

    func testFetchAccountRejectsAResponseAboutAnotherAddress() async {
        let client = makeClient(body: #"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","address":"thor1tgxm5jw6hrlvslrd6lqpk4jwuu4g29dxytrean","account_number":"42","sequence":"7"}}"#)

        do {
            _ = try await client.fetchAccount(address: address)
            XCTFail("mismatched address must not produce an account")
        } catch {
            XCTAssertEqual(error as? SendError, .accountUnavailable)
        }
    }

    func testFetchAccountMapsNonSuccessStatusToAccountUnavailable() async {
        let client = makeClient(body: "{}", statusCode: 404)

        do {
            _ = try await client.fetchAccount(address: address)
            XCTFail("404 must not produce an account")
        } catch {
            XCTAssertEqual(error as? SendError, .accountUnavailable)
        }
    }

    func testFetchAccountMapsTransportFailureToProviderUnavailable() async {
        let client = CosmosAccountClient(
            baseURL: URL(string: "https://rest.example")!,
            transport: StubTransport(result: .failure(URLError(.timedOut)))
        )

        do {
            _ = try await client.fetchAccount(address: address)
            XCTFail("transport failure must not produce an account")
        } catch {
            XCTAssertEqual(error as? SendError, .providerUnavailable)
        }
    }

    func testFetchAccountTargetsTheAuthAccountsPath() async throws {
        let recorder = StubTransport(result: .success((
            Data(#"{"account":{"@type":"/cosmos.auth.v1beta1.BaseAccount","address":"\#(address)","account_number":"1","sequence":"0"}}"#.utf8),
            200
        )))
        let client = CosmosAccountClient(baseURL: URL(string: "https://rest.example/api")!, transport: recorder)

        _ = try await client.fetchAccount(address: address)

        let url = await recorder.lastURL()
        XCTAssertEqual(url?.path, "/api/cosmos/auth/v1beta1/accounts/\(address)")
    }

    private func makeClient(body: String, statusCode: Int = 200) -> CosmosAccountClient {
        CosmosAccountClient(
            baseURL: URL(string: "https://rest.example")!,
            transport: StubTransport(result: .success((Data(body.utf8), statusCode)))
        )
    }
}

private actor StubTransport: IHttpTransport {
    private let result: Result<(Data, Int), Error>
    private var url: URL?

    init(result: Result<(Data, Int), Error>) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        url = request.url
        let (data, statusCode) = try result.get()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    func lastURL() -> URL? { url }
}
