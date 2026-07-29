package com.parasol.claims;

import java.util.List;
import java.util.OptionalLong;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import io.quarkus.hibernate.orm.panache.Panache;
import io.quarkus.narayana.jta.QuarkusTransaction;
import io.quarkus.runtime.StartupEvent;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;

/**
 * Owns the {@code claim_number_seq} database sequence that {@code POST /api/claims} draws its
 * numbers from — both making sure it exists and handing out the next value.
 *
 * <p><strong>Why a sequence at all.</strong> {@code nextval} is atomic, so concurrent requests —
 * and, crucially, concurrent <em>replicas</em> — can never be handed the same number. Several
 * modules run this service at more than one replica (the M11 HPA scales it to {@code min=2},
 * others run it at 3), which makes any "read the highest number, add one" scheme wrong by
 * construction: both pods read the same maximum and both try to insert it.
 *
 * <p><strong>Why the sequence is created here and not only in {@code import.sql}.</strong>
 * Quarkus runs {@code sql-load-script} only under the {@code drop-and-create} and {@code create}
 * schema-management strategies. The storage module overrides the strategy to {@code update} (its
 * whole lesson is that what survives a restart is decided by the volume, not by the app) and the
 * scheduling module's end state runs {@code none}, so on both of those paths {@code import.sql}
 * never executes. A sequence that exists only in the seed script therefore does not exist on the
 * very deployments that need it, and every create returns 500. This initializer runs on
 * {@code StartupEvent}, which is independent of the strategy, so the sequence exists everywhere.
 *
 * <p><strong>Where it starts.</strong> Just past the highest claim number already in the table:
 * an empty database yields {@code CLM-1001} (what the storage module's lab prints), a database
 * carrying the 30 deterministic seeds yields {@code CLM-1031} (what every other module expects).
 * Rows whose {@code claim_number} does not parse as {@code CLM-<integer>} are ignored rather than
 * thrown on.
 *
 * <p><strong>Concurrency.</strong> The create and the positioning are a SINGLE statement —
 * {@code create sequence if not exists … start with N} — deliberately, and an existing sequence
 * is never repositioned. That matters when two replicas boot at once, or when one boots while
 * another is already serving: there is no window in which the sequence exists but is positioned
 * wrongly, and a late-booting pod can never rewind a sequence a live pod is drawing from (which a
 * read-max-then-{@code ALTER SEQUENCE … RESTART} shape would do, handing out numbers that are
 * already committed rows). A replica that boots after numbers have been issued recomputes a start
 * value, finds the sequence present, and its statement is a no-op. The one residual race is two
 * replicas issuing the {@code CREATE} in the same instant: {@code IF NOT EXISTS} is a check, not a
 * lock, so PostgreSQL can still fail the loser with a duplicate-object error. That is harmless —
 * the winner created exactly the object the loser wanted — so the failure is logged and the boot
 * continues rather than crash-looping the pod.
 *
 * <p><strong>Gaps are normal.</strong> Sequence values are not rolled back, so a rejected or
 * failed create burns a number. That is the correct trade for a primary key.
 */
@ApplicationScoped
public class ClaimNumberSequence {

    private static final Logger LOG = Logger.getLogger(ClaimNumberSequence.class);

    /** The database sequence name — also spelled in {@code import.sql}; keep the two in step. */
    static final String SEQUENCE_NAME = "claim_number_seq";

    /** Every claim number is this prefix followed by the sequence value. */
    static final String PREFIX = "CLM-";

    /** The first number handed out on an empty database (storage-stateful's lab prints it). */
    static final long FIRST_NUMBER = 1001L;

    /**
     * False in the DB-free mode M21's cross-site responder and the modernization modules run the
     * same image in ({@code QUARKUS_HIBERNATE_ORM_ACTIVE=false} /
     * {@code QUARKUS_DATASOURCE_ACTIVE=false}). Touching the database at startup there would
     * crash-loop a pod whose whole point is serving {@code GET /} without one.
     */
    @ConfigProperty(name = "quarkus.hibernate-orm.active", defaultValue = "true")
    boolean hibernateActive;

    @ConfigProperty(name = "quarkus.datasource.active", defaultValue = "true")
    boolean datasourceActive;

    /**
     * Create the sequence if it is missing, positioned past the claims already stored.
     *
     * <p>Never fatal. If the schema is not there yet — the scheduling module's end state boots
     * the app with {@code schema-management=none} alongside a seed Job that may still be running,
     * and that Job's {@code import.sql} creates the sequence itself — this logs and moves on
     * rather than failing readiness.
     */
    void onStart(@Observes StartupEvent event) {
        if (!hibernateActive || !datasourceActive) {
            LOG.infof("Datasource/ORM inactive - skipping %s initialization (DB-free mode)", SEQUENCE_NAME);
            return;
        }
        try {
            long startWith = highestExistingNumber().orElse(FIRST_NUMBER - 1) + 1;
            createSequenceIfMissing(startWith);
            // Deliberately worded for both outcomes: this does NOT report where the sequence
            // actually stands. A sequence that already existed keeps its own position, which can
            // be far past `startWith`, and a log line claiming otherwise would send anyone
            // debugging claim numbers off in the wrong direction.
            LOG.infof("%s ready (created at %s%d if it was missing; an existing one is left where it is)",
                    SEQUENCE_NAME, PREFIX, startWith);
        } catch (RuntimeException e) {
            // A pod that cannot prepare the sequence must still start: it may be racing a seed Job
            // that is about to create it, or another replica that just did.
            LOG.warnf(e, "Could not initialize %s at startup; if POST /api/claims returns 500 with "
                    + "\"sequence %s does not exist\", that is why", SEQUENCE_NAME, SEQUENCE_NAME);
        }
    }

    /** The next claim number, e.g. {@code CLM-1031}. Atomic — see the class comment. */
    String next() {
        Number next = (Number) Panache.getEntityManager()
                .createNativeQuery("select nextval('" + SEQUENCE_NAME + "')")
                .getSingleResult();
        return PREFIX + next.longValue();
    }

    /**
     * Highest {@code CLM-<integer>} suffix in the claim table, or empty if there are no claims
     * (or none whose number parses). The {@code like} narrows the scan in the database; the parse
     * is done here so a hand-inserted oddity such as {@code CLM-legacy} is skipped instead of
     * failing a cast — no database-specific regex or numeric-cast syntax is needed, which keeps
     * this identical on PostgreSQL and on the H2 the tests run against.
     */
    private static OptionalLong highestExistingNumber() {
        List<?> claimNumbers = QuarkusTransaction.requiringNew().call(() -> Panache.getEntityManager()
                .createNativeQuery("select claim_number from claim where claim_number like '" + PREFIX + "%'")
                .getResultList());

        long highest = Long.MIN_VALUE;
        for (Object claimNumber : claimNumbers) {
            OptionalLong parsed = numericSuffix(String.valueOf(claimNumber));
            if (parsed.isPresent() && parsed.getAsLong() > highest) {
                highest = parsed.getAsLong();
            }
        }
        return highest == Long.MIN_VALUE ? OptionalLong.empty() : OptionalLong.of(highest);
    }

    /** The integer after {@code CLM-}, or empty when the value is not shaped like a claim number. */
    private static OptionalLong numericSuffix(String claimNumber) {
        if (!claimNumber.startsWith(PREFIX)) {
            return OptionalLong.empty();
        }
        try {
            return OptionalLong.of(Long.parseLong(claimNumber.substring(PREFIX.length())));
        } catch (NumberFormatException notANumber) {
            return OptionalLong.empty();
        }
    }

    /**
     * One statement, on purpose — see the concurrency note on the class. Standard SQL that
     * PostgreSQL and H2 both accept; no {@code ALTER SEQUENCE … RESTART} anywhere, so a sequence
     * that already exists is left exactly where it is.
     */
    private static void createSequenceIfMissing(long startWith) {
        QuarkusTransaction.requiringNew().run(() -> Panache.getEntityManager()
                .createNativeQuery("create sequence if not exists " + SEQUENCE_NAME + " start with " + startWith)
                .executeUpdate());
    }
}
