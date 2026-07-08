package com.parasol.claims;

import java.math.BigDecimal;
import java.time.LocalDate;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * A single Parasol Insurance claim.
 *
 * <p>Panache active-record entity. The business claim number (e.g. {@code CLM-1001})
 * IS the primary key — there is no separate surrogate id, which keeps the JSON and the
 * seed script ({@code import.sql}) clean and free of database sequences.
 *
 * <p>The 30 seeded rows (CLM-1001..CLM-1030) are deterministic so workshop lab text can
 * reference exact claim numbers, statuses, and amounts.
 */
@Entity
@Table(name = "claim")
public class Claim extends PanacheEntityBase {

    /** Stable business key, e.g. {@code CLM-1001}. */
    @Id
    @Column(name = "claim_number")
    public String claimNumber;

    /** Name of the insured party. */
    public String claimant;

    /** Line of business: {@code auto}, {@code home}, or {@code life}. Mapped off the
     *  reserved word "type" to keep the schema portable across PostgreSQL and H2. */
    @Column(name = "claim_type")
    public String type;

    /** Workflow state: {@code Submitted}, {@code UnderReview}, {@code Approved}, {@code Denied}. */
    public String status;

    /** Claimed amount in USD. */
    @Column(precision = 12, scale = 2)
    public BigDecimal amount;

    /** ISO-8601 date the incident occurred. */
    @Column(name = "incident_date")
    public LocalDate incidentDate;

    /** Assigned adjuster, or {@code Unassigned} for freshly submitted claims. */
    public String adjuster;
}
