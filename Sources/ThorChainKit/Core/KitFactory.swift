import CryptoKit
import Foundation

public extension Kit {
    static func instance(
        address: Address,
        walletId: String,
        endpoints: EndpointConfiguration
    ) throws -> Kit {
        guard !walletId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KitConfigurationError.invalidWalletId
        }

        var namespaceInput = Data(walletId.utf8)
        namespaceInput.append(0)
        namespaceInput.append(contentsOf: address.network.persistenceKey.utf8)
        let namespace = SHA256.hash(data: namespaceInput)
            .map { String(format: "%02x", $0) }
            .joined()

        let databaseDirectory = try databaseDirectory()
        let syncerStorage = try SyncerStorage(
            databaseDirectoryUrl: databaseDirectory,
            databaseFileName: "syncer-state-storage-\(namespace)"
        )
        let accountInfoStorage = try AccountInfoStorage(
            databaseDirectoryUrl: databaseDirectory,
            databaseFileName: "account-info-storage-\(namespace)"
        )
        let accountInfoManager = AccountInfoManager(storage: accountInfoStorage)
        let transactionStorage = try TransactionStorage(
            databaseDirectoryUrl: databaseDirectory,
            databaseFileName: "transactions-\(namespace)"
        )
        let probe = LiveNodeProbe(configuration: endpoints)
        let pool = EndpointPool(network: address.network, configuration: endpoints, probe: probe)
        let liveClient = LiveThorNodeClient(
            requestTimeout: endpoints.requestTimeout,
            clientId: endpoints.clientId,
            maximumBalancePageCount: endpoints.policy.maximumBalancePageCount
        )
        let broadcastClients = Dictionary(uniqueKeysWithValues: endpoints.families.map { family in
            (family.id, CosmosTransactionBroadcaster(baseURL: family.cosmosRestURL))
        })
        let lookupClients = Dictionary(uniqueKeysWithValues: endpoints.families.map { family in
            (family.id, CosmosTransactionLookupClient(baseURL: family.cosmosRestURL))
        })
        let accountClients = Dictionary(uniqueKeysWithValues: endpoints.families.map { family in
            (family.id, CosmosAccountClient(baseURL: family.cosmosRestURL))
        })
        let reader = ReadOperationCoordinator(
            pool: pool,
            client: liveClient,
            configuration: endpoints
        )
        let publicationBarrier = PendingPublicationBarrier()
        let journal = SendJournal(storage: transactionStorage, persistenceNamespace: namespace)
        let pendingTransactionManager = PendingTransactionManager(
            journal: journal,
            network: address.network,
            publicationBarrier: publicationBarrier
        )
        let transactionRepository = TransactionRepository(storage: transactionStorage, persistenceNamespace: namespace)
        let transactionManager = TransactionManager(
            storage: transactionStorage,
            repository: transactionRepository,
            journal: journal,
            pendingTransactionManager: pendingTransactionManager
        )
        try transactionManager.reconcileLocalTransactions()
        let transactionSyncer = endpoints.midgardURLs.isEmpty ? nil : TransactionSyncer(
            provider: MidgardProvider(
                baseURLs: endpoints.midgardURLs,
                requestTimeout: endpoints.requestTimeout,
                clientId: endpoints.clientId
            ),
            repository: transactionRepository,
            transactionManager: transactionManager,
            address: address
        )
        let transactionSender = TransactionSender(
            address: address,
            persistenceNamespace: namespace,
            journal: journal,
            reservationStore: SequenceReservationStore(storage: transactionStorage),
            broadcastOperation: { familyID, transaction in
                guard let client = broadcastClients[familyID] else { throw BroadcastTransportError.invalidEndpoint }
                return try await client.broadcast(transaction: transaction)
            },
            transactionManager: pendingTransactionManager,
            historyTransactionManager: transactionManager,
            publicationBarrier: publicationBarrier,
            lookupOperation: { familyID, transactionID in
                guard let client = lookupClients[familyID] else { return .providerInconsistent }
                return await client.lookup(transactionID: transactionID)
            },
            sendAccountOperation: { familyID, sender in
                guard let client = accountClients[familyID] else { throw SendError.accountUnavailable }
                return try await client.fetchAccount(address: sender)
            },
            // Not requestTimeout: this bounds how long a broadcast may stay undecided
            // before it is reported as unknown, and Android resolves that in ~15s too.
            operationDeadline: 15
        )
        let syncer = Syncer(
            accountInfoManager: accountInfoManager,
            reader: reader,
            storage: syncerStorage,
            address: address,
            transactionSyncer: transactionSyncer
        )
        let preflight = SendPreflightCoordinator(
            runtime: transactionSender,
            provider: ThorNodeSendPreflightProvider(
                node: ThorNodeSendClient(transport: liveClient),
                leaseProvider: { try await pool.lease(excludingFamilyIds: []) },
                capabilities: NativeRuneEndpointRegistry.capabilities().map { capability in
                    SendFamilyCapability(
                        familyID: capability.familyID,
                        manifestRevision: capability.manifestRevision,
                        routes: capability.routes.map { route in
                            SendManifestRoute(
                                record: route.record,
                                route: route.route,
                                path: route.path,
                                requestEncoding: route.requestEncoding,
                                decoder: route.decoder,
                                proofMode: route.proofMode,
                                schemaRevision: route.schemaRevision,
                                supportedNodeRevision: route.supportedNodeRevision,
                                historicalHeightParameter: route.historicalHeightParameter,
                                queryKey: route.queryKey,
                                queryParameterName: route.queryParameterName,
                                queryParameterValue: route.queryParameterValue,
                                capabilityStatus: .pass
                            )
                        }
                    )
                },
                runtime: transactionSender
            )
        )
        return Kit(
            address: address,
            syncer: syncer,
            accountInfoManager: accountInfoManager,
            transactionSender: transactionSender,
            pendingTransactionManager: pendingTransactionManager,
            transactionManager: transactionManager,
            transactionSyncer: transactionSyncer,
            preflight: preflight,
            persistenceNamespace: namespace
        )
    }

    internal static func fixture(
        address: Address,
        walletId: String,
        endpoints: EndpointConfiguration,
        transport: any TestingHTTPTransport,
        databasePath: String,
        observedAt: Date
    ) throws -> Kit {
        guard !walletId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KitConfigurationError.invalidWalletId
        }

        var namespaceInput = Data(walletId.utf8)
        namespaceInput.append(0)
        namespaceInput.append(contentsOf: address.network.persistenceKey.utf8)
        let namespace = SHA256.hash(data: namespaceInput)
            .map { String(format: "%02x", $0) }
            .joined()
        let fixtureDatabaseDirectory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        let syncerStorage = try SyncerStorage(
            databaseDirectoryUrl: fixtureDatabaseDirectory,
            databaseFileName: "syncer-state-storage-\(namespace)"
        )
        let accountInfoStorage = try AccountInfoStorage(
            databaseDirectoryUrl: fixtureDatabaseDirectory,
            databaseFileName: "account-info-storage-\(namespace)"
        )
        let accountInfoManager = AccountInfoManager(storage: accountInfoStorage)
        let transactionStorage = try TransactionStorage(path: databasePath)
        let adapter = FixtureHTTPTransportAdapter(transport: transport)
        let probe = LiveNodeProbe(configuration: endpoints, transport: adapter)
        let pool = EndpointPool(network: address.network, configuration: endpoints, probe: probe)
        let liveClient = LiveThorNodeClient(
            transport: adapter,
            requestTimeout: endpoints.requestTimeout,
            clientId: endpoints.clientId,
            maximumBalancePageCount: endpoints.policy.maximumBalancePageCount
        )
        let broadcastClients = Dictionary(uniqueKeysWithValues: endpoints.families.map { family in
            (family.id, CosmosTransactionBroadcaster(baseURL: family.cosmosRestURL, transport: adapter))
        })
        let lookupClients = Dictionary(uniqueKeysWithValues: endpoints.families.map { family in
            (family.id, CosmosTransactionLookupClient(baseURL: family.cosmosRestURL, transport: adapter))
        })
        let accountClients = Dictionary(uniqueKeysWithValues: endpoints.families.map { family in
            (family.id, CosmosAccountClient(baseURL: family.cosmosRestURL, transport: adapter))
        })
        let reader = ReadOperationCoordinator(
            pool: pool,
            client: liveClient,
            configuration: endpoints,
            wallClock: FixtureAccountReadWallClock(now: observedAt)
        )
        let publicationBarrier = PendingPublicationBarrier()
        let journal = SendJournal(storage: transactionStorage, persistenceNamespace: namespace)
        let pendingTransactionManager = PendingTransactionManager(
            journal: journal,
            network: address.network,
            publicationBarrier: publicationBarrier
        )
        let transactionRepository = TransactionRepository(storage: transactionStorage, persistenceNamespace: namespace)
        let transactionManager = TransactionManager(
            storage: transactionStorage,
            repository: transactionRepository,
            journal: journal,
            pendingTransactionManager: pendingTransactionManager
        )
        try transactionManager.reconcileLocalTransactions()
        let transactionSyncer = endpoints.midgardURLs.isEmpty ? nil : TransactionSyncer(
            provider: MidgardProvider(
                baseURLs: endpoints.midgardURLs,
                requestTimeout: endpoints.requestTimeout,
                clientId: endpoints.clientId,
                transport: adapter
            ),
            repository: transactionRepository,
            transactionManager: transactionManager,
            address: address
        )
        let transactionSender = TransactionSender(
            address: address,
            persistenceNamespace: namespace,
            journal: journal,
            reservationStore: SequenceReservationStore(storage: transactionStorage),
            broadcastOperation: { familyID, transaction in
                guard let client = broadcastClients[familyID] else { throw BroadcastTransportError.invalidEndpoint }
                return try await client.broadcast(transaction: transaction)
            },
            transactionManager: pendingTransactionManager,
            historyTransactionManager: transactionManager,
            publicationBarrier: publicationBarrier,
            lookupOperation: { familyID, transactionID in
                guard let client = lookupClients[familyID] else { return .providerInconsistent }
                return await client.lookup(transactionID: transactionID)
            },
            sendAccountOperation: { familyID, sender in
                guard let client = accountClients[familyID] else { throw SendError.accountUnavailable }
                return try await client.fetchAccount(address: sender)
            },
            // Not requestTimeout: this bounds how long a broadcast may stay undecided
            // before it is reported as unknown, and Android resolves that in ~15s too.
            operationDeadline: 15
        )
        let syncer = Syncer(
            accountInfoManager: accountInfoManager,
            reader: reader,
            storage: syncerStorage,
            address: address,
            transactionSyncer: transactionSyncer
        )
        let preflight = SendPreflightCoordinator(
            runtime: transactionSender,
            provider: ThorNodeSendPreflightProvider(
                node: ThorNodeSendClient(transport: liveClient),
                leaseProvider: { try await pool.lease(excludingFamilyIds: []) },
                capabilities: NativeRuneEndpointRegistry.capabilities().map { capability in
                    SendFamilyCapability(
                        familyID: capability.familyID,
                        manifestRevision: capability.manifestRevision,
                        routes: capability.routes.map { route in
                            SendManifestRoute(
                                record: route.record,
                                route: route.route,
                                path: route.path,
                                requestEncoding: route.requestEncoding,
                                decoder: route.decoder,
                                proofMode: route.proofMode,
                                schemaRevision: route.schemaRevision,
                                supportedNodeRevision: route.supportedNodeRevision,
                                historicalHeightParameter: route.historicalHeightParameter,
                                queryKey: route.queryKey,
                                queryParameterName: route.queryParameterName,
                                queryParameterValue: route.queryParameterValue,
                                capabilityStatus: .pass
                            )
                        }
                    )
                },
                runtime: transactionSender
            )
        )
        return Kit(
            address: address,
            syncer: syncer,
            accountInfoManager: accountInfoManager,
            transactionSender: transactionSender,
            pendingTransactionManager: pendingTransactionManager,
            transactionManager: transactionManager,
            transactionSyncer: transactionSyncer,
            preflight: preflight,
            persistenceNamespace: namespace
        )
    }

    private static func databaseDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ThorChainKit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct FixtureHTTPTransportAdapter: IHttpTransport {
    let transport: any TestingHTTPTransport

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await transport.data(for: request)
    }
}

private struct FixtureAccountReadWallClock: IAccountReadWallClock {
    let now: Date
}
