import Foundation
import GRDB

final class AccountInfoStorage {
    private let dbPool: DatabasePool

    init(databaseDirectoryUrl: URL, databaseFileName: String) throws {
        let databaseURL = databaseDirectoryUrl.appendingPathComponent("\(databaseFileName).sqlite")

        dbPool = try DatabasePool(path: databaseURL.path)
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createAccountInfo") { db in
            try db.create(table: "account_info") { table in
                table.column("id", .integer).primaryKey()
                table.column("network_chain_id", .text).notNull()
                table.column("address", .text).notNull()
                table.column("account_exists", .boolean).notNull()
                table.column("account_number", .text)
                table.column("sequence", .text)
                table.column("accepted_height", .integer).notNull()
                table.column("fetched_at", .datetime).notNull()
                table.column("provider_family_id", .text).notNull()
            }
        }

        migrator.registerMigration("createBalances") { db in
            try db.create(table: "balances") { table in
                table.column("denom", .text).primaryKey()
                table.column("amount_decimal_string", .text).notNull()
            }
        }

        return migrator
    }
}

extension AccountInfoStorage {
    func accountInfo() throws -> AccountInfoRecord? {
        try dbPool.read { db in
            guard let state = try Row.fetchOne(db, sql: "SELECT * FROM account_info WHERE id = 0") else {
                return nil
            }

            let balances = try Row.fetchAll(db, sql: "SELECT denom, amount_decimal_string FROM balances ORDER BY denom")
                .map { StoredBalance(denom: $0["denom"], amountDecimalString: $0["amount_decimal_string"]) }

            return try AccountInfoRecord(
                address: state["address"],
                networkChainId: state["network_chain_id"],
                accountExists: state["account_exists"],
                accountNumber: Self.optionalUInt64(state["account_number"]),
                sequence: Self.optionalUInt64(state["sequence"]),
                acceptedHeight: state["accepted_height"],
                fetchedAt: state["fetched_at"],
                providerFamilyId: state["provider_family_id"],
                balances: balances
            )
        }
    }

    func save(accountInfo: AccountInfoRecord) throws {
        try accountInfo.validate()

        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO account_info (id, network_chain_id, address, account_exists, account_number, sequence, accepted_height, fetched_at, provider_family_id) VALUES (0, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    accountInfo.networkChainId,
                    accountInfo.address,
                    accountInfo.accountExists,
                    accountInfo.accountNumber.map(String.init),
                    accountInfo.sequence.map(String.init),
                    accountInfo.acceptedHeight,
                    accountInfo.fetchedAt,
                    accountInfo.providerFamilyId,
                ]
            )
            try db.execute(sql: "DELETE FROM balances")
            for balance in accountInfo.balances {
                try db.execute(
                    sql: "INSERT INTO balances (denom, amount_decimal_string) VALUES (?, ?)",
                    arguments: [balance.denom, balance.amountDecimalString]
                )
            }
        }
    }

    private static func optionalUInt64(_ value: DatabaseValue) throws -> UInt64? {
        switch value.storage {
        case .null:
            return nil
        case let .int64(value):
            guard value >= 0 else { throw StorageError.invalid }
            return UInt64(value)
        case let .string(value):
            guard let result = UInt64(value), String(result) == value else {
                throw StorageError.invalid
            }
            return result
        default:
            throw StorageError.invalid
        }
    }
}
