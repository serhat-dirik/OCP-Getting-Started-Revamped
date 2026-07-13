package com.parasol.mcp.policy;

/**
 * One Parasol Insurance policy document in the seeded corpus.
 *
 * <p>The corpus is small and fixed (see {@link PolicyCorpus}) so retrieval is deterministic:
 * the same query always returns the same passages, which is what temperature-0 RAG demos need.
 *
 * @param id       stable id, e.g. {@code POL-AUTO-01}
 * @param title    short human title
 * @param category line of business or area: {@code auto}, {@code home}, {@code life}, {@code claims}
 * @param text     the policy passage the agent grounds its answer on
 */
public record PolicyDocument(String id, String title, String category, String text) {
}
