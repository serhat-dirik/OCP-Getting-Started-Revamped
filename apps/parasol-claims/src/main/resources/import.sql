-- Deterministic seed for parasol-claims: 30 claims, CLM-1001..CLM-1030.
-- Values are FIXED so workshop lab text can reference exact claim numbers,
-- statuses, amounts, and adjusters. Do NOT randomize or reorder.
--
-- Loaded by Hibernate ONLY under the drop-and-create/create schema-management
-- strategies (see application.properties) — that limit is why the sequence below is
-- not the only place claim_number_seq is created. Portable across PostgreSQL
-- (prod/dev) and H2 (tests).
--
-- Columns: claim_number, claimant, claim_type, status, amount, incident_date, adjuster
-- Spread: 12 auto / 11 home / 7 life; statuses across the workflow; freshly
-- Submitted claims are Unassigned.
--
-- Claim-number allocation. POST /api/claims takes its number from this sequence (see
-- ClaimNumberSequence), NOT from "max(claim_number) + 1" — nextval is atomic, so
-- concurrent replicas can never be handed the same number.
--
-- WHY THIS STAYS HERE even though ClaimNumberSequence creates the sequence at startup
-- under every strategy: the two do different jobs. The startup path guarantees the
-- sequence EXISTS. These two lines RESET it, together with the data, on every
-- drop-and-create boot — and that is what makes "the first created claim is CLM-1031"
-- deterministic for the modules that reseed. Measured with the sequence pushed to 5000
-- and the app rebooted: with these lines the reseeded database hands out CLM-1031; with
-- them removed it hands out CLM-5001, because Hibernate drops the TABLES it manages and
-- never touches a sequence that is not in the entity model. The startup path cannot
-- substitute: it deliberately leaves an existing sequence alone (rewinding one another
-- replica is drawing from would re-issue live claim numbers).
-- Harmless overlap: under drop-and-create these run first, so the startup path finds the
-- sequence present and its CREATE ... IF NOT EXISTS is a no-op.
-- Standard SQL: verified identical on PostgreSQL 15.18 (prod/dev) and H2 2.4.240 (tests).
DROP SEQUENCE IF EXISTS claim_number_seq;
CREATE SEQUENCE claim_number_seq START WITH 1031 INCREMENT BY 1;
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1001', 'Alice Nguyen', 'auto', 'UnderReview', 4200.00, '2026-05-14', 'Rebecca Torres');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1002', 'Marcus Feld', 'home', 'Approved', 12850.00, '2026-05-09', 'Marcus Johnson');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1003', 'Priya Raman', 'auto', 'Submitted', 1975.50, '2026-06-01', 'Unassigned');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1004', 'Tom Becker', 'home', 'Denied', 8400.00, '2026-04-22', 'Angela Davis');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1005', 'Sofia Alvarez', 'life', 'Approved', 25000.00, '2026-03-30', 'David Okonkwo');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1006', 'Michael Turner', 'auto', 'UnderReview', 11800.00, '2026-01-20', 'Rebecca Torres');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1007', 'Karen Foster', 'home', 'Approved', 28000.00, '2025-08-14', 'Angela Davis');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1008', 'David Park', 'auto', 'UnderReview', 16900.00, '2025-12-28', 'Rebecca Torres');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1009', 'Emily Watson', 'home', 'Submitted', 47800.00, '2025-12-01', 'Unassigned');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1010', 'Robert Chen', 'auto', 'Approved', 18500.00, '2025-10-03', 'Marcus Johnson');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1011', 'James Rodriguez', 'auto', 'Denied', 42000.00, '2025-09-22', 'Rebecca Torres');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1012', 'Patricia O''Brien', 'home', 'UnderReview', 31500.00, '2026-01-08', 'Marcus Johnson');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1013', 'Linda Park', 'life', 'Approved', 50000.00, '2025-11-15', 'David Okonkwo');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1014', 'Dennis Wright', 'auto', 'Submitted', 3300.00, '2026-06-10', 'Unassigned');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1015', 'Grace Kim', 'home', 'Approved', 9600.00, '2026-02-17', 'Angela Davis');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1016', 'Samuel Ortiz', 'life', 'UnderReview', 75000.00, '2025-10-29', 'David Okonkwo');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1017', 'Nina Petrova', 'auto', 'Approved', 6750.00, '2026-03-05', 'Marcus Johnson');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1018', 'Hassan Ali', 'home', 'Denied', 15400.00, '2025-09-12', 'Angela Davis');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1019', 'Olivia Brooks', 'auto', 'UnderReview', 2200.00, '2026-04-30', 'Rebecca Torres');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1020', 'Ethan Cole', 'life', 'Submitted', 40000.00, '2026-06-18', 'Unassigned');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1021', 'Maria Santos', 'home', 'Approved', 22300.00, '2026-02-02', 'Angela Davis');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1022', 'Kevin Zhang', 'auto', 'Approved', 5100.00, '2025-11-27', 'Marcus Johnson');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1023', 'Rachel Green', 'life', 'UnderReview', 60000.00, '2025-12-19', 'David Okonkwo');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1024', 'Daniel Mbeki', 'home', 'Submitted', 13750.00, '2026-05-25', 'Unassigned');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1025', 'Laura Bianchi', 'auto', 'Denied', 9900.00, '2025-10-15', 'Rebecca Torres');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1026', 'George Adams', 'home', 'Approved', 34200.00, '2026-01-31', 'Angela Davis');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1027', 'Chloe Martin', 'life', 'Approved', 45000.00, '2025-09-08', 'David Okonkwo');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1028', 'Victor Osei', 'auto', 'UnderReview', 7800.00, '2026-03-22', 'Marcus Johnson');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1029', 'Amara Okafor', 'home', 'UnderReview', 19250.00, '2026-04-11', 'Angela Davis');
INSERT INTO claim (claim_number, claimant, claim_type, status, amount, incident_date, adjuster) VALUES ('CLM-1030', 'Frank Miller', 'life', 'Submitted', 30000.00, '2026-06-27', 'Unassigned');

-- Claim audit timeline (claim_event). Backs GET /api/claims/{claimNumber}/history,
-- which loads each event by id in a loop (a DELIBERATE N+1 for observability-health-scale's tracing lab -
-- see ClaimResource.history). Ids are FIXED and seed-controlled. CLM-1001 has the
-- richest history (5 events) so its history call issues a visible 1+5 = 6 queries.
-- Columns: id, claim_number, event_type, note, created_at
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (1, 'CLM-1001', 'Submitted', 'Claim submitted via portal', '2026-05-14 09:12:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (2, 'CLM-1001', 'AdjusterAssigned', 'Assigned to Rebecca Torres', '2026-05-14 14:30:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (3, 'CLM-1001', 'DocumentsRequested', 'Requested repair estimate and photos', '2026-05-15 10:05:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (4, 'CLM-1001', 'DocumentsReceived', 'Estimate and photos received', '2026-05-18 16:45:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (5, 'CLM-1001', 'UnderReview', 'Adjuster review in progress', '2026-05-19 08:20:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (6, 'CLM-1002', 'Submitted', 'Claim submitted via portal', '2026-05-09 08:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (7, 'CLM-1002', 'AdjusterAssigned', 'Assigned to Marcus Johnson', '2026-05-09 11:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (8, 'CLM-1002', 'UnderReview', 'Adjuster review in progress', '2026-05-10 09:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (9, 'CLM-1002', 'Approved', 'Approved for 12850.00', '2026-05-12 15:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (10, 'CLM-1002', 'PaymentIssued', 'Payment issued to policyholder', '2026-05-14 10:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (11, 'CLM-1003', 'Submitted', 'Claim submitted via portal', '2026-06-01 12:30:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (12, 'CLM-1004', 'Submitted', 'Claim submitted via portal', '2026-04-22 07:45:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (13, 'CLM-1004', 'AdjusterAssigned', 'Assigned to Angela Davis', '2026-04-22 13:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (14, 'CLM-1004', 'UnderReview', 'Adjuster review in progress', '2026-04-24 10:30:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (15, 'CLM-1004', 'Denied', 'Denied - outside policy coverage', '2026-04-28 16:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (16, 'CLM-1005', 'Submitted', 'Claim submitted via portal', '2026-03-30 09:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (17, 'CLM-1005', 'AdjusterAssigned', 'Assigned to David Okonkwo', '2026-03-31 10:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (18, 'CLM-1005', 'UnderReview', 'Adjuster review in progress', '2026-04-02 11:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (19, 'CLM-1005', 'Approved', 'Approved for 25000.00', '2026-04-06 14:00:00');
INSERT INTO claim_event (id, claim_number, event_type, note, created_at) VALUES (20, 'CLM-1005', 'PaymentIssued', 'Payment issued to beneficiary', '2026-04-09 10:00:00');
