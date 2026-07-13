package com.parasol.claims.legacy.config;

import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.EnableWebMvc;

/*
 * Spring MVC enablement for the WAR. @EnableWebMvc + component scan is the classic servlet-stack
 * setup MTA maps onto a modern, embedded framework during replatforming.
 */
@Configuration
@EnableWebMvc
@ComponentScan(basePackages = { "com.parasol.claims.legacy" })
public class WebConfig {
}
