package com.parasol.claims.legacy.exception.handler;

import com.parasol.claims.legacy.exception.ResourceNotFoundException;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.ResponseStatus;

@ControllerAdvice
public class ExceptionHandlingController {

    @ResponseStatus(HttpStatus.NOT_FOUND)
    @ExceptionHandler(ResourceNotFoundException.class)
    public void handleNotFound(ResourceNotFoundException e) {
        // ISSUE (MTA): console logging instead of a structured logger / error tracking.
        System.out.println("Claim not found: " + e.getMessage());
    }
}
