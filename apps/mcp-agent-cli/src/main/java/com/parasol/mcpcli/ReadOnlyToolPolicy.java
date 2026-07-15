package com.parasol.mcpcli;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.Set;

/**
 * Decides whether a tool name is read-only, for the CLI's <strong>read-only-first</strong> posture.
 *
 * <p>The rule is a simple, server-neutral denylist: the tool name is split into word tokens (on
 * {@code _ - . /} and camelCase boundaries) and the tool is treated as mutating if any <em>whole
 * token</em> is a write verb ({@code create}, {@code delete}, {@code patch}, {@code apply},
 * {@code scale}, {@code exec}, ...). Whole-token matching (rather than substring) is deliberate: it
 * flags {@code scale_deployment} and {@code pods_delete} without misfiring on read tools whose
 * <em>nouns</em> merely contain a verb - {@code get_deployment} ("deploy"), {@code replicasets_list}
 * ("set") - which a substring match would wrongly hide. It hard-codes no single MCP server's tool
 * names, so the client stays assistant- and server-neutral (kubernetes-mcp-server, openshift-mcp-server,
 * or any other).
 *
 * <p><strong>This heuristic is defense-in-depth, not the security boundary.</strong> M24's lesson
 * (reinforced by CVE-2026-46519, where a sibling server's read-only flag filtered tool discovery but
 * not execution) is that <em>RBAC - the ServiceAccount's grants - is the boundary; a read-only flag
 * is a seatbelt.</em> {@link ReadOnlyToolFilter} applies this policy by removing a mutating tool's
 * <em>executor</em> as well as its spec, so the model can neither see nor invoke it through this
 * client - but a differently-configured client, or the server with the flag off, could still attempt
 * a write, and only RBAC will stop it. The imperfection of a name-based denylist is itself part of
 * the teaching point.
 */
public final class ReadOnlyToolPolicy {

    /**
     * Default write verbs, matched against whole name tokens (case-insensitive). Catches
     * {@code pods_delete}, {@code resources_create_or_update}, {@code scale_deployment},
     * {@code pods_exec}, {@code pods_run}, {@code deployment_restart}, and the like, without
     * misfiring on read tools like {@code get_deployment} or {@code replicasets_list}.
     */
    public static final Set<String> DEFAULT_MUTATING_TOKENS = Set.of(
            "create", "update", "delete", "remove", "patch", "apply", "replace", "edit",
            "write", "set", "put", "post", "add", "scale", "exec", "run", "deploy",
            "rollout", "restart", "cordon", "uncordon", "drain", "evict", "kill",
            "annotate", "label", "attach", "expose", "rollback", "taint", "start", "stop");

    private final Set<String> mutatingTokens;

    public ReadOnlyToolPolicy() {
        this(DEFAULT_MUTATING_TOKENS);
    }

    public ReadOnlyToolPolicy(Set<String> mutatingTokens) {
        this.mutatingTokens = Set.copyOf(mutatingTokens);
    }

    /** Parse a comma/space separated token list (from config) into a policy; blank falls back to the default. */
    public static ReadOnlyToolPolicy fromTokens(String csv) {
        if (csv == null || csv.isBlank()) {
            return new ReadOnlyToolPolicy();
        }
        List<String> tokens = java.util.Arrays.stream(csv.split("[,\\s]+"))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .map(s -> s.toLowerCase(Locale.ROOT))
                .toList();
        return tokens.isEmpty() ? new ReadOnlyToolPolicy() : new ReadOnlyToolPolicy(Set.copyOf(tokens));
    }

    /**
     * If {@code toolName} looks mutating, the write verb it matched (for logging/reporting);
     * otherwise empty. The first name token (left to right) that is a write verb is returned, so the
     * result is deterministic. A {@code null} name is treated as mutating (fail closed).
     */
    public Optional<String> mutatingToken(String toolName) {
        if (toolName == null) {
            return Optional.of("<null>");
        }
        for (String token : tokenize(toolName)) {
            if (mutatingTokens.contains(token)) {
                return Optional.of(token);
            }
        }
        return Optional.empty();
    }

    /** Split a tool name into lowercase word tokens on {@code _ - . /} and camelCase boundaries. */
    static List<String> tokenize(String name) {
        String spaced = name
                .replaceAll("([a-z0-9])([A-Z])", "$1 $2")   // camelCase -> "camel Case"
                .replaceAll("[^A-Za-z0-9]+", " ");
        List<String> tokens = new ArrayList<>();
        for (String part : spaced.trim().split("\\s+")) {
            if (!part.isEmpty()) {
                tokens.add(part.toLowerCase(Locale.ROOT));
            }
        }
        return tokens;
    }

    /** True if the tool is read-only (safe to expose under read-only mode). */
    public boolean isReadOnly(String toolName) {
        return mutatingToken(toolName).isEmpty();
    }

    Set<String> mutatingTokens() {
        return mutatingTokens;
    }
}
