package com.parasol.claims.legacy.repository;

import com.parasol.claims.legacy.model.Claim;
import org.springframework.data.repository.PagingAndSortingRepository;

public interface ClaimRepository extends PagingAndSortingRepository<Claim, Long> {
}
