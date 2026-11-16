# How it ships

## Every push to `main`: the build pipeline

| Task | What it guarantees |
|---|---|
| `fetch-source` | The pipeline builds exactly the pushed commit |
| `unit-tests` | A failing test stops the run |
| `build-image` | The image is built and pushed; Tekton Chains signs it, keyless |
| `scan` | Red Hat Advanced Cluster Security checks it against the build policies |
| `sbom` | A CycloneDX bill of materials is stored with the image digest |
| `verify-conforma` | Signature, provenance and policy verify before anything deploys |
| `deploy-dev` | The verified digest is committed to `overlays/dev`; Argo CD deploys it |

Only a commit that passed every task can be released.

## A tag `vX.Y.Z`: the release pipeline

The release verifies the same image again, promotes its digest to stage, waits for stage to be
healthy, then promotes it to prod. Prod is an Argo Rollouts canary: part of the traffic moves
to the new version, an analysis checks it, and the rollout completes or rolls back on its own.
