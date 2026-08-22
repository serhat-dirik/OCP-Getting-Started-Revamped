package com.parasol.claims;

import java.util.UUID;

import org.jboss.logmanager.MDC;

import jakarta.ws.rs.container.ContainerRequestContext;
import jakarta.ws.rs.container.ContainerRequestFilter;
import jakarta.ws.rs.container.ContainerResponseContext;
import jakarta.ws.rs.container.ContainerResponseFilter;
import jakarta.ws.rs.ext.Provider;

/**
 * Give every HTTP request an id, put it in the logging context, and hand it back to the caller.
 *
 * <p><strong>Why this exists (curriculum: Application Logging).</strong> Once a service runs more
 * than one replica, "show me the log line for that request" stops having an answer: the reply the
 * user saw came from one pod out of three and nothing in the log says which. A correlation id fixes
 * that, and it has to be carried by the log <em>record</em> rather than pasted into the message,
 * because a field can be queried and a sentence cannot.
 *
 * <p>The carrier is the <em>MDC</em> — the mapped diagnostic context, a per-request map the logging
 * backend attaches to every record written on that thread. Each entry becomes a field of its own in
 * the structured output ({@code "mdc":{"requestId":"…"}}) without any log statement having to
 * mention it, which is the point: the id reaches lines written by code that never heard of it.
 * {@code quarkus-smallrye-context-propagation} is already on this app's classpath, so the context
 * survives the async hops Quarkus makes between the I/O thread and the worker.
 *
 * <p>Two details that are easy to get wrong and are deliberate here:
 * <ul>
 *   <li>The incoming header is caller-controlled, so it goes through {@link LogSafe} before it is
 *       allowed anywhere near a log record — see that class for what an unsanitized one buys an
 *       attacker.</li>
 *   <li>The MDC is <em>cleared</em> on the way out. Request threads are pooled and reused; leave
 *       the entry behind and the next request on that thread inherits somebody else's id, which is
 *       worse than having none at all because it is confidently wrong.</li>
 * </ul>
 */
@Provider
public class RequestIdFilter implements ContainerRequestFilter, ContainerResponseFilter {

    /** The de-facto standard correlation header. Gateways, meshes and browsers all speak it. */
    public static final String HEADER = "X-Request-Id";

    /** MDC key, and therefore the field name in the structured log line. */
    public static final String MDC_KEY = "requestId";

    @Override
    public void filter(ContainerRequestContext request) {
        String incoming = request.getHeaderString(HEADER);
        String id = (incoming == null || incoming.isBlank())
                ? UUID.randomUUID().toString().substring(0, 8)
                : LogSafe.value(incoming);
        MDC.put(MDC_KEY, id);
        request.setProperty(MDC_KEY, id);
    }

    @Override
    public void filter(ContainerRequestContext request, ContainerResponseContext response) {
        Object id = request.getProperty(MDC_KEY);
        if (id != null) {
            // Hand it back so the caller can quote it in a support ticket — the id is only useful
            // if both ends of the conversation know it.
            response.getHeaders().putSingle(HEADER, id);
        }
        MDC.remove(MDC_KEY);
    }
}
