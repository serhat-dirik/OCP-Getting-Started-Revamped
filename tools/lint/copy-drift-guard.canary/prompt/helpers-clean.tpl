{{/* Fixture for tools/lint/copy-drift-guard.py --self-test. NOT part of the canary CHART: it
     sits outside chart/ so `helm template` never loads it, because the helm_define extractor reads
     the .tpl as TEXT (a define in _helpers.tpl is not reachable through --show-only at all).

     Paired with prompt/GroundingFixture.java, and deliberately NOT byte-identical to it. The two
     differences are exactly the two the normalizer is allowed to erase, so this fixture failing
     would mean a normalization rule stopped working:
       N1  the blank line below carries trailing spaces, and one line ends in a tab. Java strips
           per-line trailing white space itself; the ConfigMap that ships the real Helm copy strips
           it back off after `indent` puts it on.
       N2  `{{- end -}}` chomps the trailing newline the Java text block's closing delimiter adds.
     Everything else — every word, and the two-space continuation indent — is verbatim. */}}

{{/* A DECOY, so the extractor has to select by name rather than take the first define it finds. */}}
{{- define "canary.decoyPrompt" -}}
You are a decoy. If this text is what got compared, the extractor picked the wrong
define and the pair is gating something nobody meant to gate.
{{- end -}}

{{- define "canary.fixturePrompt" -}}
You are a canary prompt. These words are what must not drift.
   
Rules:
- Keep the continuation below indented two extra spaces, because relative	
  indentation is part of the prompt and normalization must not flatten it.
- The closing delimiter sits on its own line, so this value ends in one newline
  while the Helm side's does not.
{{- end -}}
