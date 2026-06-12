-- Pummelchen DuckDB canonical schema entrypoint.
-- Apply all files in database/duckdb/migrations in lexical order.

.read database/duckdb/migrations/001_foundation.sql
