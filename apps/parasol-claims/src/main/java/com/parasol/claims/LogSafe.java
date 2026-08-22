package com.parasol.claims;

import java.util.regex.Pattern;

/**
 * Neutralize a caller-controlled string before it reaches a log line.
 *
 * <p><strong>Why this exists (curriculum: Application Logging).</strong> Every value in this
 * service that comes off the wire — a claim number in the path, a correlation id in a header — is
 * chosen by whoever called us. Write one of those into a log line unchanged and the caller, not
 * you, decides what your log file says: a claim number of {@code CLM-1\n2026-08-22 INFO [audit]
 * claim CLM-9999 approved} forges a second, entirely fictional log entry. That is log injection,
 * and it is the reason a log line is treated here as untrusted output, not as a string.
 *
 * <p>The rule this class implements is the same one the module teaches for credentials: the safety
 * must be a transformation <em>of the thing</em> — by shape, here, since a claim number and a
 * correlation id are both bounded identifier tokens — and never a character count that happens to
 * fall short of the payload. The 64-character cap below is a bound on an <em>already neutralized</em>
 * token, applied after the substitution rather than instead of it.
 */
final class LogSafe {

    /** Everything outside this class is replaced. Covers the identifier shapes this API accepts. */
    private static final Pattern UNSAFE = Pattern.compile("[^A-Za-z0-9._:-]");

    /** Longest token kept. A correlation id past this length is a payload, not an id. */
    private static final int MAX = 64;

    /** Anything that can start a new record or an escape sequence, in a free-text message. */
    private static final Pattern RECORD_BREAKING = Pattern.compile("[\\p{Cntrl}]");

    private LogSafe() {
    }

    /**
     * Return {@code value} with every character outside {@code [A-Za-z0-9._:-]} replaced by
     * {@code _}, capped at 64 characters. Newlines, carriage returns, ANSI escapes and quoting
     * characters all go, so the result cannot open a second log record or close a JSON string.
     *
     * @param value a caller-supplied string, possibly {@code null}
     * @return a token that is safe to interpolate into a log line; {@code "-"} for null/blank
     */
    static String value(String value) {
        if (value == null || value.isBlank()) {
            return "-";
        }
        String cleaned = UNSAFE.matcher(value).replaceAll("_");
        return cleaned.length() <= MAX ? cleaned : cleaned.substring(0, MAX);
    }

    /**
     * The weaker sibling of {@link #value}, for a message that has to stay readable English and so
     * cannot be reduced to an identifier alphabet. It removes only what can forge a <em>record</em>
     * — newlines, carriage returns, and the rest of the control range including ANSI escapes.
     *
     * <p>Use this only where the free text is unavoidable, and prefer {@link #value} on the
     * individual caller-supplied fragment wherever the message can be composed instead.
     *
     * @param message a log message that may embed caller-supplied text
     * @return the same message on exactly one line
     */
    static String text(String message) {
        return message == null ? "-" : RECORD_BREAKING.matcher(message).replaceAll(" ");
    }
}
