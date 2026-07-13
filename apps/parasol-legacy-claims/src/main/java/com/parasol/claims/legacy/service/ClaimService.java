package com.parasol.claims.legacy.service;

import org.jboss.logging.Logger;
import com.parasol.claims.legacy.model.Claim;
import com.parasol.claims.legacy.repository.ClaimRepository;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@Transactional
public class ClaimService {

    @Autowired
    private ClaimRepository repository;

    private static final Logger logger = Logger.getLogger(ClaimService.class.getName());

    public Claim findById(Long id) {
        logger.debug("Entering ClaimService.findById()");
        Claim c = repository.findById(id).orElse(null);
        logger.debug("Returning element: " + c);
        return c;
    }

    public Page<Claim> findAll(Pageable pageable) {
        logger.debug("Entering ClaimService.findAll()");
        return repository.findAll(pageable);
    }
}
