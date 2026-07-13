package com.parasol.mcp.policy;

import java.util.List;

/**
 * The seeded Parasol policy corpus — eight short, fixed documents.
 *
 * <p>Embedded in code (not a vector store) on purpose: the app layer for M23 uses simple,
 * deterministic keyword retrieval so the "grounded vs ungrounded" and "RAG honestly" beats
 * land without a GPU or an embeddings model. The production pgvector/Milvus path is a later
 * platform phase. Several documents deliberately describe the claims workflow, statuses, SLAs
 * and payout timing, so the agent can combine a RAG lookup here with a claims-db tool call.
 *
 * <p>Do NOT randomize or reorder — lab text references these ids and facts.
 */
final class PolicyCorpus {

    private PolicyCorpus() {
    }

    static final List<PolicyDocument> DOCUMENTS = List.of(
            new PolicyDocument("POL-AUTO-01", "Auto Collision Coverage and Deductible", "auto", """
                    Parasol auto policies cover collision, theft, fire and third-party liability for
                    the insured vehicle. The standard deductible for an auto collision claim is 500
                    USD per incident; the policyholder pays the deductible and Parasol pays the
                    remaining approved repair cost. Rental-car reimbursement of up to 40 USD per day
                    for a maximum of 30 days is included while the insured vehicle is being repaired.
                    """),
            new PolicyDocument("POL-AUTO-02", "Auto Claim Filing Requirements", "auto", """
                    To file an auto claim the policyholder must submit photographs of the damage and a
                    repair estimate from an approved body shop. For theft or vandalism a police report
                    filed within 72 hours of the incident is required. Claims for incidents older than
                    30 days may be denied unless a valid reason for the delay is provided.
                    """),
            new PolicyDocument("POL-HOME-01", "Home Property Damage Coverage", "home", """
                    Parasol home policies cover sudden and accidental property damage including fire,
                    smoke, windstorm, hail, and water damage from a burst internal pipe. The standard
                    home deductible is 1000 USD per claim. Flood and earthquake are NOT covered by the
                    base policy and require a separate rider. Gradual damage from long-term leaks or
                    lack of maintenance is excluded.
                    """),
            new PolicyDocument("POL-HOME-02", "Home Claim Documentation", "home", """
                    A home property claim requires an itemized list of damaged or lost property, dated
                    photographs of the damage, and receipts or proof of ownership for high-value items.
                    Parasol may send an adjuster to inspect the property before approving claims above
                    10000 USD.
                    """),
            new PolicyDocument("POL-LIFE-01", "Life Policy Benefit and Beneficiary", "life", """
                    A Parasol life policy pays a lump-sum death benefit to the named beneficiary on
                    validation of the claim. Claims are subject to a two-year contestability period
                    during which Parasol may review the original application for material
                    misstatement. A certified death certificate and the completed claim form are
                    required to begin processing.
                    """),
            new PolicyDocument("POL-CLAIM-01", "Claim Workflow and Status Definitions", "claims", """
                    Every Parasol claim moves through four workflow statuses. Submitted means the claim
                    has been received but not yet assigned. UnderReview means an adjuster has been
                    assigned and is evaluating the claim and its documents. Approved means the claim
                    has been accepted and is scheduled for payment. Denied means the claim was
                    rejected, for example because the loss falls outside policy coverage.
                    """),
            new PolicyDocument("POL-CLAIM-02", "Claim Review Service Levels", "claims", """
                    Parasol targets first adjuster contact within 3 business days of a claim being
                    submitted. A standard claim receives a decision within 10 business days of moving
                    to UnderReview. Complex claims — for example large property losses or claims
                    requiring an on-site inspection — may take up to 30 business days.
                    """),
            new PolicyDocument("POL-CLAIM-03", "Payment After Approval", "claims", """
                    Once a claim is Approved, Parasol issues payment within 5 business days. Auto and
                    home claim payments are made to the policyholder (or directly to an approved repair
                    shop on request); life claim payments are made to the named beneficiary. Payment is
                    net of any unpaid deductible.
                    """));
}
