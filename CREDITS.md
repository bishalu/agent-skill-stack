# Credits

Almost every skill in this stack was written by someone else. This repository adds
curation, routing metadata, a router, and an eval harness. The skills are upstream work
and the credit for them belongs upstream.

## Compound Engineering

[EveryInc/compound-engineering-plugin](https://github.com/EveryInc/compound-engineering-plugin)
by Kieran Klaassen and Trevin Chow at [Every](https://every.to). MIT.

The backbone. Brainstorm, plan, work, simplify, review, compound. It installs unmodified
from the upstream marketplace, this repo changes nothing about it, and it does most of
the work here. The essay behind it is
[worth reading](https://every.to/source-code/my-ai-had-already-fixed-the-code-before-i-saw-it).

## Matt Pocock

[mattpocock/skills](https://github.com/mattpocock/skills) by Matt Pocock. MIT.

Six skills vendored, four with a rewritten `description`. The rewrites change when each
skill activates so it stops racing Compound Engineering. The methodology inside is
Matt's and is untouched: the deep-module vocabulary, the diagnosis loop, the
red-green-refactor discipline. His collection is worth installing whole if you are not
running Compound alongside it. `claude plugin install mattpocock-skills`.

## Vercel Labs

[vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills) by Vercel Labs.
MIT.

Five skills vendored, all five with adjusted descriptions. The React and Next.js
performance rules, the composition patterns, and the Web Interface Guidelines are Vercel
Engineering's work, and the 40-odd rule files under `rules/` are theirs verbatim.

## Trail of Bits

[trailofbits/skills](https://github.com/trailofbits/skills) by
[Trail of Bits](https://www.trailofbits.com). **CC BY-SA 4.0.**

Eleven plugins forked into a local marketplace so their routing metadata can be
narrowed. Five descriptions changed. Every skill body, reference file, agent, hook, and
script is theirs unmodified.

The ShareAlike term matters. The forked plugins under `build/marketplace/` derive from
CC BY-SA 4.0 material, so they stay CC BY-SA 4.0, with attribution and a statement of
changes. `scripts/build.py` writes both into `build/marketplace/NOTICE.md` on every
build. Redistribute this repo's build output and that licence travels with it.

## Amazon Web Services

[aws/agent-toolkit-for-aws](https://github.com/aws/agent-toolkit-for-aws) by Amazon Web
Services. Apache 2.0.

The `aws-core` plugin, forked and trimmed from 21 skills to 9. The trim is the only
change to the skills themselves, which are AWS's work unmodified. The plugin manifest's
description was rewritten, because the upstream blurb advertises CDK, CloudFormation,
Neptune, Keyspaces and the Swift SDK, none of which survive the trim.

## HashiCorp

[hashicorp/agent-skills](https://github.com/hashicorp/agent-skills) by HashiCorp.
**MPL 2.0.**

Three of sixteen Terraform skills, vendored: `terraform-style-guide`, `refactor-module`,
`terraform-test`. The other thirteen are for authors of Terraform providers, or are
Azure and paid HCP products.

MPL 2.0 is file-level weak copyleft. Those three files stay MPL and are marked as such
in their provenance records. The rest of this repo is unaffected.

## Cursor

[cursor/plugins](https://github.com/cursor/plugins) by Cursor, with per-plugin authors.
MIT.

Three skills vendored. `cli-for-agents` is Cursor's, under `cli-for-agent/`. `unslop`
and `why` come from the `pstack` plugin, copyright 2026 Lauren Tan. `unslop` edited this
README, which is the most direct credit I can give it.

## This repository

The curation manifest, the build and install scripts, the `engineering-router` skill,
the routing eval harness and corpus, the fixture repo, and the documentation. MIT, see
[LICENSE](LICENSE). That is the only original content here.

## Licence summary

| Component | Licence | Holder |
|---|---|---|
| Compound Engineering plugin | MIT | Every Inc. |
| Vendored Pocock skills | MIT | Matt Pocock |
| Vendored Vercel skills | MIT | Vercel Labs |
| Vendored Cursor skills | MIT | Cursor, Lauren Tan |
| Vendored HashiCorp skills | **MPL 2.0** | HashiCorp |
| Forked Trail of Bits plugins (`build/marketplace/`) | **CC BY-SA 4.0** | Trail of Bits |
| Forked AWS plugin (`build/marketplace-aws/`) | Apache 2.0 | Amazon Web Services |
| Everything else | MIT | this repo |
