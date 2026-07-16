-- claims-db schema for the M16 SOLVE/end state — captured from parasol-claims:1.1's own Hibernate
-- drop-and-create output (pg_dump --schema-only, verified live 2026-07-16) so it matches the entity
-- mapping EXACTLY. Loaded ONCE by the claims-db-seed Job (with import.sql) so the app can run with
-- schema-management=none: a rolling-update pod boot no longer drops+reseeds the shared DB (the M16
-- lesson). Idempotent (DROP … IF EXISTS) so the seed Job is safe to re-run. Keep in sync with the
-- entity classes in apps/parasol-claims/src/main/java/com/parasol/claims/ if they change.
DROP TABLE IF EXISTS claim_event;
DROP TABLE IF EXISTS claim;

CREATE TABLE claim (
    claim_number  character varying(255) NOT NULL,
    claimant      character varying(255),
    claim_type    character varying(255),
    status        character varying(255),
    amount        numeric(12,2),
    incident_date date,
    adjuster      character varying(255),
    CONSTRAINT claim_pkey PRIMARY KEY (claim_number)
);

CREATE TABLE claim_event (
    id           bigint NOT NULL,
    claim_number character varying(255),
    event_type   character varying(255),
    note         character varying(255),
    created_at   timestamp(6) without time zone,
    CONSTRAINT claim_event_pkey PRIMARY KEY (id)
);
