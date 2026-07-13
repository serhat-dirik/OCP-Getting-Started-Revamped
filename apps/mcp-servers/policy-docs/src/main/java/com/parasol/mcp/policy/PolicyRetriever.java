package com.parasol.mcp.policy;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Deterministic keyword retrieval over the seeded {@link PolicyCorpus}.
 *
 * <p>Scoring is a transparent weighted term-frequency count (title matches weigh more than body
 * matches). No embeddings, no vector store, no model call — so it runs anywhere and returns the
 * SAME ranking every time, which is exactly what the "RAG honestly / grounded vs ungrounded"
 * teaching beat needs at temperature 0. The production pgvector/Milvus retriever is a later
 * platform phase; the tool contract ({@code search_policies}) stays identical when it lands.
 */
@ApplicationScoped
public class PolicyRetriever {

    private static final int TITLE_WEIGHT = 3;
    private static final int BODY_WEIGHT = 1;
    private static final int MIN_TOKEN_LENGTH = 2;

    /** Common words dropped from queries so scoring keys off meaningful terms. */
    private static final Set<String> STOPWORDS = Set.of(
            "the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "is", "are", "be",
            "do", "does", "what", "how", "my", "it", "that", "this", "with", "as", "at", "by",
            "from", "will", "can", "if", "per", "up", "i", "me", "you", "your", "was", "were");

    /** A corpus document plus its precomputed title/body term-frequency maps. */
    private record Indexed(PolicyDocument doc, Map<String, Integer> titleTf, Map<String, Integer> bodyTf) {
    }

    private final List<Indexed> index = new ArrayList<>();

    @PostConstruct
    void build() {
        for (PolicyDocument doc : PolicyCorpus.DOCUMENTS) {
            index.add(new Indexed(doc, termFrequencies(doc.title()), termFrequencies(doc.text())));
        }
    }

    /**
     * Top {@code maxResults} policy passages for a natural-language query, best match first.
     * Ties break by document id so the ordering is stable. Documents with no query-term hit are
     * omitted; an all-stopword or empty query yields no matches.
     */
    public List<PolicyMatch> search(String query, int maxResults) {
        int limit = Math.min(Math.max(maxResults, 1), PolicyCorpus.DOCUMENTS.size());
        Set<String> terms = tokenize(query);
        if (terms.isEmpty()) {
            return List.of();
        }
        List<PolicyMatch> scored = new ArrayList<>();
        for (Indexed entry : index) {
            int score = 0;
            for (String term : terms) {
                score += TITLE_WEIGHT * entry.titleTf().getOrDefault(term, 0);
                score += BODY_WEIGHT * entry.bodyTf().getOrDefault(term, 0);
            }
            if (score > 0) {
                scored.add(PolicyMatch.of(entry.doc(), score));
            }
        }
        scored.sort(Comparator.comparingInt(PolicyMatch::score).reversed()
                .thenComparing(PolicyMatch::id));
        return scored.size() > limit ? scored.subList(0, limit) : scored;
    }

    /** One policy document by its id (case-insensitive), or empty. */
    public Optional<PolicyDocument> get(String id) {
        if (id == null) {
            return Optional.empty();
        }
        String wanted = id.trim();
        return PolicyCorpus.DOCUMENTS.stream()
                .filter(d -> d.id().equalsIgnoreCase(wanted))
                .findFirst();
    }

    /** The whole corpus (used by the catalog tool). */
    public List<PolicyDocument> all() {
        return PolicyCorpus.DOCUMENTS;
    }

    private static Set<String> tokenize(String text) {
        return termFrequencies(text).keySet();
    }

    private static Map<String, Integer> termFrequencies(String text) {
        Map<String, Integer> tf = new HashMap<>();
        if (text == null) {
            return tf;
        }
        for (String token : text.toLowerCase().split("[^a-z0-9]+")) {
            if (token.length() < MIN_TOKEN_LENGTH || STOPWORDS.contains(token)) {
                continue;
            }
            tf.merge(token, 1, Integer::sum);
        }
        return tf;
    }
}
