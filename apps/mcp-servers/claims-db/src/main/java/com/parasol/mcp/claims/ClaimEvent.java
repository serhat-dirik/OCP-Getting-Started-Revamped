package com.parasol.mcp.claims;

import java.time.LocalDateTime;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * One entry in a claim's audit timeline (e.g. Submitted -&gt; AdjusterAssigned -&gt;
 * UnderReview -&gt; Approved). Backs the {@code get_claim_history} MCP tool.
 *
 * <p>Same shape and seed ids as {@code parasol-claims}' {@code ClaimEvent}. The link to a
 * claim is the plain {@code claim_number} column (no JPA relationship), which keeps this
 * read-only facade small and its queries obvious.
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
