// Fixture for tools/lint/copy-drift-guard.py --self-test. NEVER COMPILED and never on any
// Maven source root: it exists only so the guard's java_text_block extractor is exercised by the
// self-test rather than by the real tree alone. What is tested here is the DETECTOR, not the
// Parasol agent's prompt — a canary derived from the live file quietly turns into an exit 2 the
// day that file changes shape (the mistake the guard this replaced made with import.sql).
package canary;

class GroundingFixture {

    // A DECOY, first on purpose: the extractor must select by NAME, not take the first text block
    // it sees. Its words differ from FIXTURE_PROMPT's, so an extractor that grabbed this one would
    // report drift on the clean canary and the self-test would fail.
    static final String DECOY_PROMPT = """
            You are a decoy. If this text is what got compared, the extractor picked the wrong
            constant and the pair is gating something nobody meant to gate.
            """;

    // The one the canary pairs compare. Deliberately carries the two shapes that matter:
    //   * a continuation line indented two spaces FURTHER than its neighbours — relative
    //     indentation is part of a prompt and no normalization may flatten it;
    //   * a blank line in the middle, which the Helm copy writes with trailing spaces.
    static final String FIXTURE_PROMPT = """
            You are a canary prompt. These words are what must not drift.

            Rules:
            - Keep the continuation below indented two extra spaces, because relative
              indentation is part of the prompt and normalization must not flatten it.
            - The closing delimiter sits on its own line, so this value ends in one newline
              while the Helm side's does not.
            """;
}
