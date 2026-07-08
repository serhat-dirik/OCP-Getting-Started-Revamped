package com.parasol.web;

/**
 * A single insurance claim shown on the Parasol claims portal.
 *
 * <p>The data is deterministic and seeded in-process: this frontend is a
 * self-contained black box (module M01 deploys it as a prebuilt image with no
 * backend). The richer CLM-1001..CLM-1030 dataset lives in the {@code parasol-claims}
 * service that arrives in later modules.
 *
 * @param id           stable claim identifier, e.g. {@code CLM-1001}
 * @param policyholder name of the insured party
 * @param type         line of business (Auto, Home, Property, ...)
 * @param status       workflow state (Open, Under Review, Approved, Denied, Closed)
 * @param amount       claimed amount in USD
 * @param filedDate    ISO-8601 date the claim was filed
 */
public record Claim(
        String id,
        String policyholder,
        String type,
        String status,
        double amount,
        String filedDate) {
}
