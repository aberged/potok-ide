-- One database per scale, so a 10k seed never mixes with a 1k run.
CREATE DATABASE potok_load_1k;
CREATE DATABASE potok_load_10k;

\connect potok_load_1k
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

\connect potok_load_10k
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
