{{/* Fixture for tools/lint/copy-drift-guard.py --self-test. NOT part of the canary CHART: it
     sits outside chart/ so `helm template` never loads it, because the helm_define extractor reads
     the .tpl as TEXT (a define in _helpers.tpl is not reachable through --show-only at all).

     The DRIFTED twin of helpers-clean.tpl: ONE WORD changed (drift -> wobble), nothing else.
     One word is the smallest real defect this pair can suffer, and the one that a verify script
     grading a PROPERTY of the prompt — does it direct the model at its tools — cannot see.

     It carries the same two normalizer-erasable differences from prompt/GroundingFixture.java as
     its clean twin does (N1 trailing spaces and a tab, N2 the newline `{{- end -}}` chomps), so
     the word is the only thing left that can make this pair report drift. If it ever reports
     something else, a normalization rule has stopped working — not this fixture. */}}

{{/* A DECOY, so the extractor has to select by name rather than take the first define it finds. */}}
{{- define "canary.decoyPrompt" -}}
You are a decoy. If this text is what got compared, the extractor picked the wrong
define and the pair is gating something nobody meant to gate.
{{- end -}}

{{- define "canary.fixturePrompt" -}}
You are a canary prompt. These words are what must not wobble.
   
Rules:
- Keep the continuation below indented two extra spaces, because relative	
  indentation is part of the prompt and normalization must not flatten it.
- The closing delimiter sits on its own line, so this value ends in one newline
  while the Helm side's does not.
{{- end -}}
