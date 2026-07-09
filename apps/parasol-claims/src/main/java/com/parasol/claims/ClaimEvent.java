package com.parasol.claims;

import java.time.LocalDateTime;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * One entry in a claim's audit timeline (e.g. Submitted -&gt; AdjusterAssigned -&gt;
 * UnderReview -&gt; Approved).
 *
 * <p>Backs {@code GET /api/claims/{claimNumber}/history}. The id is an explicit,
 * seed-controlled {@code Long} (no sequence) so the deterministic rows in
 * {@code import.sql} own their ids and the history endpoint can load each event by
 * primary key — which is exactly how it produces its <em>deliberate</em> N+1 query
 * pattern for the M11 tracing exercise. There is intentionally no JPA relationship to
 * {@link Claim}; the link is the plain {@code claim_number} column.
 */
@Entity
@Table(name = "claim_event")
public class ClaimEvent extends PanacheEntityBase {

    /** Seed-controlled primary key (assigned in import.sql; not generated). */
    @Id
    public Long id;

    /** The business claim number this event belongs to, e.g. {@code CLM-1001}. */
    @Column(name = "claim_number")
    public String claimNumber;

    /** What happened: {@code Submitted}, {@code AdjusterAssigned}, {@code UnderReview}, ... */
    @Column(name = "event_type")
    public String eventType;

    /** Human-readable note for the timeline entry. */
    public String note;

    /** When the event occurred (drives the timeline order). */
    @Column(name = "created_at")
    public LocalDateTime createdAt;
}
