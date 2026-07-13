package com.parasol.claims.legacy.model;

import javax.persistence.Column;
import javax.persistence.Entity;
import javax.persistence.GeneratedValue;
import javax.persistence.GenerationType;
import javax.persistence.Id;
import javax.persistence.SequenceGenerator;
import javax.persistence.Table;

/*
 * JPA entity for a Parasol insurance claim. javax.persistence (JPA 2.x / Java EE) — MTA flags the
 * javax->jakarta namespace move as part of the modernization to current runtimes.
 */
@Entity
@Table(name = "claims")
public class Claim {

    @Id
    @SequenceGenerator(
        name = "claimsSequence",
        sequenceName = "claims_id_seq",
        allocationSize = 1,
        initialValue = 6)
    @GeneratedValue(strategy = GenerationType.SEQUENCE, generator = "claimsSequence")
    private Long id;

    @Column(name = "claim_number", length = 20)
    private String claimNumber;

    @Column(length = 40)
    private String policyHolder;

    @Column(length = 30)
    private String category;

    @Column(length = 20)
    private String status;

    @Column(name = "amount_usd")
    private Double amountUsd;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public String getClaimNumber() {
        return claimNumber;
    }

    public void setClaimNumber(String claimNumber) {
        this.claimNumber = claimNumber;
    }

    public String getPolicyHolder() {
        return policyHolder;
    }

    public void setPolicyHolder(String policyHolder) {
        this.policyHolder = policyHolder;
    }

    public String getCategory() {
        return category;
    }

    public void setCategory(String category) {
        this.category = category;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public Double getAmountUsd() {
        return amountUsd;
    }

    public void setAmountUsd(Double amountUsd) {
        this.amountUsd = amountUsd;
    }

    @Override
    public String toString() {
        return "Claim [id=" + id + ", claimNumber=" + claimNumber + ", policyHolder=" + policyHolder
            + ", category=" + category + ", status=" + status + ", amountUsd=" + amountUsd + "]";
    }
}
