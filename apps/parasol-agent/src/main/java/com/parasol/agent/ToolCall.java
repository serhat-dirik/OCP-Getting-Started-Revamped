package com.parasol.agent;

/**
 * One tool the agent invoked while answering: the tool {@code name}, the JSON {@code arguments}
 * the model passed, and (when available) the tool {@code result}. Reported in the
 * {@code POST /agent/ask} response so a lab can see exactly which "API" the agent called.
 */
public record ToolCall(String tool, String arguments, String result) {
}
