import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "ledger") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("defaultCurrency", .text).notNull()
                audit(t)
            }
            try db.create(table: "participant") { t in
                t.primaryKey("id", .text)
                t.belongsTo("ledger", onDelete: .restrict).notNull()
                t.column("name", .text).notNull()
                audit(t)
            }
            try db.create(table: "member") { t in
                t.primaryKey("id", .text)
                t.belongsTo("ledger", onDelete: .restrict).notNull()
                t.belongsTo("participant", onDelete: .restrict).notNull()
                t.column("actorId", .text).notNull()
                t.column("role", .text).notNull()
                audit(t)
                t.uniqueKey(["ledgerId", "actorId"])
            }
            try db.create(table: "expense") { t in
                t.primaryKey("id", .text)
                t.belongsTo("ledger", onDelete: .restrict).notNull()
                t.column("merchant", .text).notNull()
                t.column("note", .text)
                t.column("category", .text)
                t.column("occurredAt", .datetime).notNull()
                t.column("timeZone", .text).notNull()
                t.column("currency", .text).notNull()
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("horizontalAccuracy", .double)
                t.column("locationSource", .text)
                t.column("source", .text).notNull()
                audit(t)
            }
            try db.create(table: "expenseLine") { t in
                t.primaryKey("id", .text)
                t.belongsTo("expense", onDelete: .cascade).notNull()
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("quantity", .integer).notNull()
                t.column("unitMinor", .integer)
                t.column("amountMinor", .integer).notNull()
                t.column("splitRule", .text).notNull()
                t.column("sortOrder", .integer).notNull()
            }
            try db.create(table: "lineConsumer") { t in
                t.column("lineId", .text).notNull().references("expenseLine", onDelete: .cascade)
                t.belongsTo("participant", onDelete: .restrict).notNull()
                t.column("weight", .integer).notNull().defaults(to: 1)
                t.column("exactMinor", .integer)
                t.primaryKey(["lineId", "participantId"])
            }
            try db.create(table: "expensePayment") { t in
                t.belongsTo("expense", onDelete: .cascade).notNull()
                t.belongsTo("participant", onDelete: .restrict).notNull()
                t.column("amountMinor", .integer).notNull().check { $0 > 0 }
                t.column("method", .text)
                t.primaryKey(["expenseId", "participantId"])
            }
            try db.create(table: "transfer") { t in
                t.primaryKey("id", .text)
                t.belongsTo("ledger", onDelete: .restrict).notNull()
                t.column("fromParticipantId", .text).notNull().references("participant", onDelete: .restrict)
                t.column("toParticipantId", .text).notNull().references("participant", onDelete: .restrict)
                t.column("currency", .text).notNull()
                t.column("amountMinor", .integer).notNull().check { $0 > 0 }
                t.column("settlesCurrency", .text).notNull()
                t.column("settlesMinor", .integer).notNull().check { $0 > 0 }
                t.column("method", .text)
                t.column("externalRef", .text)
                t.column("occurredAt", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("note", .text)
                audit(t)
            }
            try db.create(table: "journalTx") { t in
                t.primaryKey("id", .text)
                t.belongsTo("ledger", onDelete: .restrict).notNull()
                t.column("sourceType", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.column("occurredAt", .datetime).notNull()
                t.column("reversesTxId", .text).references("journalTx", onDelete: .restrict)
            }
            try db.create(table: "journalEntry") { t in
                t.primaryKey("id", .text)
                t.column("txId", .text).notNull().references("journalTx", onDelete: .cascade)
                t.belongsTo("participant", onDelete: .restrict).notNull()
                t.column("currency", .text).notNull()
                t.column("amountMinor", .integer).notNull()
                t.column("lineId", .text).references("expenseLine", onDelete: .cascade)
            }
            try db.create(indexOn: "journalEntry", columns: ["participantId", "currency"])
            try db.create(indexOn: "expense", columns: ["ledgerId", "occurredAt"])
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                t.belongsTo("ledger", onDelete: .cascade).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.belongsTo("conversation", onDelete: .cascade).notNull()
                t.column("role", .text).notNull()
                t.column("text", .text).notNull()
                t.column("status", .text).notNull()
                t.column("error", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(indexOn: "message", columns: ["conversationId", "createdAt"])
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "ledger") { t in
                t.add(column: "settlementCurrency", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE ledger SET settlementCurrency = defaultCurrency")
            try db.create(table: "exchangeRate") { t in
                t.belongsTo("ledger", onDelete: .cascade).notNull()
                t.column("currency", .text).notNull()
                t.column("rate", .text).notNull()
                t.column("source", .text).notNull()
                t.column("asOf", .text)
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["ledgerId", "currency"])
            }
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "message") { t in
                t.add(column: "kind", .text).notNull().defaults(to: "text")
                t.add(column: "payload", .text)
                t.add(column: "proposalState", .text)
                t.add(column: "expenseId", .text).references("expense", onDelete: .setNull)
            }
        }
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                ALTER TABLE conversation ADD COLUMN agentHistoryVersion INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE agentRun (
                    id TEXT PRIMARY KEY NOT NULL,
                    conversationId TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                    userMessageId TEXT NOT NULL REFERENCES message(id),
                    status TEXT NOT NULL CHECK (status IN ('running','complete','failed','aborted','interrupted')),
                    error TEXT,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE UNIQUE INDEX agentRun_active ON agentRun(conversationId) WHERE status = 'running';
                CREATE TABLE agentTranscript (
                    conversationId TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    runId TEXT REFERENCES agentRun(id),
                    sourceMessageId TEXT,
                    formatVersion INTEGER NOT NULL DEFAULT 1,
                    payload TEXT NOT NULL,
                    PRIMARY KEY (conversationId, id),
                    UNIQUE (conversationId, sequence)
                );
                CREATE TABLE agentToolExecution (
                    conversationId TEXT NOT NULL,
                    assistantMessageId TEXT NOT NULL,
                    toolCallId TEXT NOT NULL,
                    name TEXT NOT NULL,
                    arguments TEXT NOT NULL,
                    result TEXT NOT NULL,
                    proposalId TEXT REFERENCES message(id),
                    completedAt DATETIME NOT NULL,
                    PRIMARY KEY (conversationId, assistantMessageId, toolCallId),
                    FOREIGN KEY (conversationId, assistantMessageId) REFERENCES agentTranscript(conversationId, id) ON DELETE CASCADE
                );
                ALTER TABLE message ADD COLUMN agentRunId TEXT REFERENCES agentRun(id);
                ALTER TABLE message ADD COLUMN agentMessageId TEXT;
                CREATE UNIQUE INDEX message_agent ON message(conversationId, agentMessageId);
                """)
        }
        migrator.registerMigration("v6") { db in
            try db.create(table: "place") { t in
                t.primaryKey("id", .text)
                t.belongsTo("ledger", onDelete: .cascade).notNull()
                t.column("name", .text).notNull()
                t.column("branch", .text)
                t.column("address", .text)
                t.column("phone", .text)
                t.column("category", .text)
                t.column("latitude", .double).notNull()
                t.column("longitude", .double).notNull()
                t.column("provider", .text).notNull()
                t.column("providerId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["ledgerId", "provider", "providerId"])
            }
            try db.alter(table: "expense") { t in
                t.add(column: "placeId", .text).references("place", onDelete: .setNull)
                t.add(column: "placeQuery", .text)
            }
        }
        migrator.registerMigration("v7") { db in
            try db.alter(table: "expense") { t in
                t.add(column: "endsAt", .datetime)
                t.add(column: "originalCurrency", .text)
                t.add(column: "originalMinor", .integer)
            }
        }
        return migrator
    }

    private static func audit(_ t: TableDefinition) {
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("deletedAt", .datetime)
        t.column("version", .integer).notNull()
        t.column("createdBy", .text).notNull()
        t.column("updatedBy", .text).notNull()
    }
}
