package com.parasol.mcp.policy;

/**
 * A scored retrieval hit returned by the {@code search_policies} tool: the matched policy
 * passage plus the relevance {@code score} the deterministic retriever assigned it. The agent
 * reads {@code text} to ground its answer and can cite {@code id}/{@code title} as the source.
 */
public record PolicyMatch(String id, String title, String category, int score, String text) {

    static PolicyMatch of(PolicyDocument doc, int score) {
        return new PolicyMatch(doc.id(), doc.title(), doc.category(), score, doc.text());
    }
}
