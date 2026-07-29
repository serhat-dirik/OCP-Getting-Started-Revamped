-- Canary fixture for copy-drift-guard.py, mode "bytes". Not applied anywhere.
-- The CREATE SEQUENCE line is MISSING on purpose: this is the real 2026-07-29 defect, and the
-- byte detector must report it. A guard that calls this pair clean is blind.
INSERT INTO canary (id, label) VALUES (1, 'first');
INSERT INTO canary (id, label) VALUES (2, 'second');
