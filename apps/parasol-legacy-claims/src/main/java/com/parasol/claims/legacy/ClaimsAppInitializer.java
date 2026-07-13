package com.parasol.claims.legacy;

import javax.servlet.ServletContext;
import javax.servlet.ServletException;
import javax.servlet.ServletRegistration;

import org.springframework.web.WebApplicationInitializer;
import org.springframework.web.context.ContextLoaderListener;
import org.springframework.web.context.support.AnnotationConfigWebApplicationContext;
import org.springframework.web.servlet.DispatcherServlet;

/*
 * Servlet-era bootstrap: registers the Spring DispatcherServlet programmatically against the
 * container's ServletContext (javax.servlet). MTA flags this as a classic servlet/WAR pattern
 * that must move to an embedded, containerized runtime for OpenShift.
 */
public class ClaimsAppInitializer implements WebApplicationInitializer {

    @Override
    public void onStartup(ServletContext container) throws ServletException {
        AnnotationConfigWebApplicationContext context = new AnnotationConfigWebApplicationContext();
        context.setConfigLocation("com.parasol.claims.legacy.config");
        context.scan("com.parasol.claims.legacy");
        container.addListener(new ContextLoaderListener(context));

        ServletRegistration.Dynamic dispatcher =
            container.addServlet("dispatcher", new DispatcherServlet(context));
        dispatcher.setLoadOnStartup(1);
        dispatcher.addMapping("/");
    }
}
