Rules every milestone must honor. `ce-plan` quotes a matching rule into the plan as a constraint; `ce-code-review` flags a diff that contradicts one.

One markdown file per invariant, named for the rule (`tunables-live-in-config.md`). The frontmatter decides when a rule fires: `title` states the rule as a sentence, `applies_when` lists the situations in which it matters, in the words a plan or a diff would use. The body says why the rule exists and what to do instead. The invariants the milestone-supervisor skill lists belong here in this project's own words: mutable data is seeded, never rebuilt; replay fixtures are keyed on prompt text; derived keys move when their derivation changes; tunables live in config.

A rule reads like this:

```markdown
---
title: Thresholds and model ids are read from config, never hardcoded
applies_when:
  - adding a threshold, weight or limit to scoring or ranking
  - naming a model id in code
tags: [config, thresholds, models]
---

A bake-off winner is configuration, so the next milestone changes it without a code edit. Read the value from the project's config file; a literal in code is a finding.
```
