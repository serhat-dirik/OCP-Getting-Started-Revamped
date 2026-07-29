-- Canary fixture for copy-drift-guard.py, mode "bytes". Not applied anywhere.
-- Shaped like apps/parasol-claims/src/main/resources/import.sql, whose entry-state copy silently
-- lost exactly this kind of statement on 2026-07-29.
CREATE SEQUENCE canary_number_seq START WITH 1000 INCREMENT BY 1;
INSERT INTO canary (id, label) VALUES (1, 'first');
INSERT INTO canary (id, label) VALUES (2, 'second');
