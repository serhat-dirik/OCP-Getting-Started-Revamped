package com.parasol.claims.legacy.controller;

import org.jboss.logging.Logger;
import com.parasol.claims.legacy.exception.ResourceNotFoundException;
import com.parasol.claims.legacy.model.Claim;
import com.parasol.claims.legacy.service.ClaimService;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/claims")
public class ClaimController {

    @Autowired
    private ClaimService claimService;

    private static final Logger logger = Logger.getLogger(ClaimController.class.getName());

    @GetMapping(value = "/{id}", produces = MediaType.APPLICATION_JSON_VALUE)
    public Claim getById(@PathVariable("id") Long id) {
        Claim c = claimService.findById(id);
        if (c == null) {
            throw new ResourceNotFoundException("Requested claim doesn't exist");
        }
        logger.debug("Returning element: " + c);
        return c;
    }

    @RequestMapping
    public Page<Claim> findAll(Pageable pageable) {
        return claimService.findAll(pageable);
    }
}
