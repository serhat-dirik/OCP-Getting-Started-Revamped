package com.parasol.claims.legacy.config;

import java.util.Properties;

import javax.sql.DataSource;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.dao.annotation.PersistenceExceptionTranslationPostProcessor;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.EnableTransactionManagement;

/*
 * JPA/DataSource wiring built from persistence.properties. Every value (driver, URL, credentials,
 * ddl mode, dialect) is read from a properties FILE baked into the WAR — MTA flags this as
 * externalize-configuration (cloud-readiness): on OpenShift these belong in a ConfigMap/Secret and
 * env vars, not a compiled-in file.
 */
@Configuration
@EnableJpaRepositories(basePackages = { "com.parasol.claims.legacy.repository" })
@EnableTransactionManagement
public class PersistenceConfig {

    @Bean
    public LocalContainerEntityManagerFactoryBean entityManagerFactory() {
        final LocalContainerEntityManagerFactoryBean em = new LocalContainerEntityManagerFactoryBean();
        em.setDataSource(dataSource());
        em.setPackagesToScan("com.parasol.claims.legacy.model");
        em.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        em.setJpaProperties(additionalProperties());
        return em;
    }

    @Bean
    public DataSource dataSource() {
        ApplicationConfiguration config = new ApplicationConfiguration();
        final DriverManagerDataSource dataSource = new DriverManagerDataSource();
        dataSource.setDriverClassName(config.getProperty("jdbc.driverClassName"));
        dataSource.setUrl(config.getProperty("jdbc.url"));
        dataSource.setUsername(config.getProperty("jdbc.user"));
        dataSource.setPassword(config.getProperty("jdbc.password"));
        return dataSource;
    }

    @Bean
    public PlatformTransactionManager transactionManager() {
        final JpaTransactionManager transactionManager = new JpaTransactionManager();
        transactionManager.setEntityManagerFactory(entityManagerFactory().getObject());
        return transactionManager;
    }

    @Bean
    public PersistenceExceptionTranslationPostProcessor exceptionTranslation() {
        return new PersistenceExceptionTranslationPostProcessor();
    }

    final Properties additionalProperties() {
        ApplicationConfiguration config = new ApplicationConfiguration();
        final Properties hibernateProperties = new Properties();
        // ISSUE (MTA): create-drop hbm2ddl — data-destructive, never for a real environment.
        hibernateProperties.setProperty("hibernate.hbm2ddl.auto", config.getProperty("hibernate.hbm2ddl.auto"));
        hibernateProperties.setProperty("hibernate.dialect", config.getProperty("hibernate.dialect"));
        return hibernateProperties;
    }
}
