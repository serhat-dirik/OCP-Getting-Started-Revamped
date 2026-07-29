-- TEST FIXTURE ONLY (ClaimNumberingMixedDataTest) — not shipped in the image, not a workshop seed.
-- A claim table that is neither empty nor the deterministic 30-claim seed, and that deliberately
-- contains rows the claim-number parser must survive: a suffix that is not an integer, and a number
-- with no CLM- prefix at all. It also creates NO sequence, which is the whole point — this is the
-- one fixture where ClaimNumberSequence has to compute a start position from real data rather than
-- find claim_number_seq already made by import.sql.
-- Highest parseable suffix here is 2048, so the first created claim must be CLM-2049.
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1001', 'Alice Nguyen', 'auto', 'UnderReview', 4200.00, '2026-05-14', 'Rebecca Torres');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-2048', 'Higher Number', 'home', 'Submitted', 900.00, '2026-06-02', 'Unassigned');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-legacy-7', 'Unparseable Suffix', 'life', 'Approved', 100.00, '2026-06-03', 'Unassigned');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('LEGACY-99999', 'No CLM Prefix', 'auto', 'Denied', 100.00, '2026-06-04', 'Unassigned');
