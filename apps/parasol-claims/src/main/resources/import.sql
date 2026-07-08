-- Deterministic seed for parasol-claims: 30 claims, CLM-1001..CLM-1030.
-- Values are FIXED so workshop lab text can reference exact claim numbers,
-- statuses, amounts, and adjusters. Do NOT randomize or reorder.
--
-- Loaded by Hibernate on drop-and-create (see application.properties). Portable
-- across PostgreSQL (prod/dev) and H2 (tests): plain INSERTs, no sequences.
--
-- Columns: claim_number, claimant, claim_type, status, amount, incident_date, adjuster
-- Spread: 12 auto / 11 home / 7 life; statuses across the workflow; freshly
-- Submitted claims are Unassigned.
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
