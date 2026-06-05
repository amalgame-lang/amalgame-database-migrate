# amalgame-database-migrate

A small, **safety-first** schema-migration runner for
[`amalgame-database-sqlite`](https://github.com/amalgame-lang/amalgame-database-sqlite).

You register ordered migrations (each with an `up` and an optional
`down` SQL block); the `Migrator` tracks which have been applied in a
`schema_migrations` table and brings the database forward (`Up`) or back
(`Down` / `DownTo`) **one transaction at a time**.

## Why a tool instead of running SQL by hand

The whole point of a migration tool is to make schema changes *safe and
repeatable*, so the runner is strict by construction:

- migrations run in **ascending version order**, regardless of the order
  you registered them;
- each migration runs inside its **own transaction** — on any error the
  runner rolls *that* migration back and **stops**, so the schema never
  drifts into a half-applied state;
- already-applied versions are **skipped** (`Up` is idempotent — safe to
  run on every boot);
- a `Down` rollback **refuses** a migration that declared no `down` SQL
  (an irreversible step must be explicit, never silently skipped);
- **duplicate versions are rejected**;
- the tracking-table name is validated as a plain identifier and the
  applied-version record is written with **bound parameters**.

## Install

```sh
amc package add database-sqlite
amc package add database-migrate
```

## Use

```amalgame
import Amalgame.Database.SQLite
import Amalgame.Database.Migrate

let db = SQLite.Open("app.db")

let m = new Migrator()
m.Add(1, "create_users",
      "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE)",
      "DROP TABLE users")
m.Add(2, "add_users_name",
      "ALTER TABLE users ADD COLUMN name TEXT",
      "")                         // "" → irreversible (Down refuses it)

let r = m.Up(db)
if (!r.Ok) {
    Console.WriteLine("migration failed: " + r.Error)   // schema untouched past the failure
} else {
    Console.WriteLine(r.Message)                          // "applied 2 migration(s)"
}

Console.WriteLine("schema is at v" + String_FromInt(m.Current(db)))   // 2
```

Roll back the most recent migration, or down to a target version:

```amalgame
m.Down(db)          // undo the latest (if it declared down SQL)
m.DownTo(db, 0)     // undo everything reversible, newest-first
```

## API

| Type | Member | Purpose |
|------|--------|---------|
| `Migration` | `Migration(version, name, up, down)` | one step; `down=""` ⇒ irreversible |
| `Migrator` | `Add(version, name, up, down)` / `AddMigration(m)` | register a step |
| | `WithTable(name)` | override the tracking table (default `schema_migrations`) |
| | `Up(db)` → `MigrateResult` | apply all pending, ascending, transactional, fail-stop |
| | `Down(db)` → `MigrateResult` | roll back the most recent (reversible) step |
| | `DownTo(db, target)` → `MigrateResult` | roll back until `Current ≤ target` |
| | `Current(db)` → `int` | highest applied version (0 if none) |
| | `Pending(db)` → `List<int>` | registered-but-not-applied versions |
| `MigrateResult` | `Ok`, `Error`, `Message`, `Applied`, `RolledBack` | outcome |

## Notes

- **SQLite only** for now. The DB packages are header-based (no AM
  facade), so the runner is typed against the concrete `SQLite` handle;
  a PostgreSQL sibling is a future addition.
- Migration `up`/`down` SQL is developer-authored (trusted) — the threat
  the runner defends against is *partial / inconsistent application*, not
  SQL injection. (User input belongs nowhere near migration SQL.)

## License

Apache-2.0.
