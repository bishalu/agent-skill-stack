# Eval results

Every file here is the output of `eval/run-eval.py`, kept as evidence rather than
summary. Each holds the prompt, the accept and forbid lists, and the exact skills that
fired on every run, so any claim in [ROUTING-EVAL.md](../../ROUTING-EVAL.md) can be
checked against the raw observation.

`rescore.py` reads these back and re-scores them against the current corpus without
spending anything, which is how several early "failures" turned out to be bad
expectations rather than bad routing.

## The runs that matter

| File | What it is |
|---|---|
| `final-corpus.json` | Latest full corpus sweep. 26 cases, 52 sessions, 100%, zero duplicate owners |
| `final-heldout.json` | Latest held-out sweep. 22 cases, 44 sessions, 96%, zero duplicate owners |
| `sweep-1.json` | The first sweep, before any description was tuned. Useful as a baseline |

## The rest

`probe-*` files are collision probes written to test a specific worry: whether MLflow's
`fix-agent-issue` would steal the implementation phase, whether `launch-with-aws` would
claim a deployment request, whether the AWS and Python overlays fire at all. Two of them
sit at 0% and are kept deliberately, because that is where the `claude-api` suppression
and the weak `modern-python` trigger were found.

`round2-*` and `round3-*` are re-runs of individual cases after a description change.
`retest-*` and `rbp-*` are the same thing for the two overlay reliability passes, each
paired with the negative cases the change was most likely to break.

A file scoring 0% is not a defect left in the repo. It is the measurement that caused a
fix, and the fix is recorded in `curation.json` under that skill's `reason`.

## Reproducing

```bash
python3 eval/run-eval.py --runs 2                    # corpus
python3 eval/run-eval.py --corpus eval/heldout.jsonl --runs 2
```

Roughly 100 headless sessions and about $12 on Opus. Use `--case` or `--tag` while
iterating.
