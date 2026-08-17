import Foundation
import GRDB

final class SyncerStorage {
    private let dbPool: DatabasePool

    init(databaseDirectoryUrl: URL, databaseFileName: String) throws {
        let databaseURL = databaseDirectoryUrl.appendingPathComponent("\(databaseFileName).sqlite")

        dbPool = try DatabasePool(path: databaseURL.path)
        try migrator.migrate(dbPool)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createLastBlockHeight") { db in
            try db.create(table: "last_block_height") { table in
                table.column("id", .integer).primaryKey()
                table.column("height", .integer).notNull()
            }
        }

        return migrator
    }
}

extension SyncerStorage {
    var lastBlockHeight: Int64? {
        try? dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT height FROM last_block_height WHERE id = 0")?["height"]
        }
    }

    func save(lastBlockHeight: Int64) throws {
        guard lastBlockHeight > 0 else { throw StorageError.invalid }

        try dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO last_block_height (id, height) VALUES (0, ?)",
                arguments: [lastBlockHeight]
            )
        }
    }
}
