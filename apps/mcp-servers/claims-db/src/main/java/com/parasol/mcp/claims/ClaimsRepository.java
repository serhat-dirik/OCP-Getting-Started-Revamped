package com.parasol.mcp.claims;

import java.util.List;
import java.util.Optional;
import java.util.Set;

import io.quarkus.panache.common.Sort;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.transaction.Transactional;

/**
 * Read-only data access over the seeded claims dataset.
 *
 * <p>All methods are {@code @Transactional} because Panache queries need an active session,
 * and every method maps entities to {@link ClaimView} records (or plain strings) INSIDE the
 * transaction, so nothing lazy escapes to the tool layer. Kept deliberately tiny - the whole
 * server is a thin, deterministic facade over 30 fixed claims.
 */
@ApplicationScoped
public class ClaimsRepository {

    /** Canonical workflow states, matched case-insensitively for the status tool. */
    static final Set<String> STATUSES = Set.of("Submitted", "UnderReview", "Approved", "Denied");

    /** One claim by its (normalized) business number. */
    @Transactional
    public Optional<ClaimView> find(String claimNumber) {
        Claim c = Claim.findById(normalize(claimNumber));
        return Optional.ofNullable(c).map(ClaimView::of);
    }

    /** Every claim in the given workflow status (canonicalized), sorted by claim number. */
    @Transactional
    public List<ClaimView> byStatus(String status) {
        String canonical = canonicalStatus(status);
        if (canonical == null) {
            return List.of();
        }
        List<Claim> claims = Claim.list("status = ?1 order by claimNumber", canonical);
        return claims.stream().map(ClaimView::of).toList();
    }

    /** The audit timeline for a claim, oldest event first; empty if the claim has no events. */
    @Transactional
    public List<ClaimEvent> history(String claimNumber) {
        return ClaimEvent.list("claimNumber", Sort.by("createdAt"), normalize(claimNumber));
    }

    /** Whether a claim with this (normalized) number exists. */
    @Transactional
    public boolean exists(String claimNumber) {
        return Claim.count("claimNumber", normalize(claimNumber)) > 0;
    }

    /**
     * Forgiving claim-number normalization so the model's tool call works whether it passes
     * {@code "clm-1001"}, {@code "CLM-1001"}, or a bare {@code "1001"}.
     */
    static String normalize(String claimNumber) {
        if (claimNumber == null) {
            return null;
        }
        String s = claimNumber.trim().toUpperCase();
        if (s.matches("\\d{3,}")) {
            s = "CLM-" + s;
        }
        return s;
    }

    /** Map a loosely-typed status (any case, optional spaces) to the canonical value, or null. */
    static String canonicalStatus(String status) {
        if (status == null) {
            return null;
        }
        String compact = status.trim().replace(" ", "");
        for (String s : STATUSES) {
            if (s.equalsIgnoreCase(compact)) {
                return s;
            }
        }
        return null;
    }
}
