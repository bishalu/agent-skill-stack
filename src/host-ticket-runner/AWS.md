# AWS for ticket agents: the owner's checklist

A ticket agent never holds admin AWS access. It holds one provisioned, least-privilege key, and until the owner provisions that key it holds none. Creating the principal and the key is the owner's job; nothing in this skill creates IAM resources.

## What the runner already does

Every run's environment is rebuilt before `claude` starts:

- **Scrubbed:** every variable whose name starts with `AWS_`, so the named keys (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_SSO_*`, `AWS_CONTAINER_*`) go, and so do non-standard copies a shell profile may export (`AWS_SEC`, `AWS_ID`).
- **Pointed at the runner's files:** `AWS_CONFIG_FILE=HTR_HOME/aws/config`, `AWS_SHARED_CREDENTIALS_FILE=HTR_HOME/aws/credentials`, `AWS_PROFILE=htr-agent`, `AWS_SDK_LOAD_CONFIG=1`, `AWS_EC2_METADATA_DISABLED=true`. Neither file references an SSO session, a `credential_process` or a role, so nothing in the real `~/.aws` (its SSO and CLI caches included) is ever consulted. Until a key is installed the credentials file holds an empty `[htr-agent]` profile, and every AWS call fails with "Unable to locate credentials".
- **Denied:** a `PreToolUse` hook refuses any file tool or Bash command that names the real `~/.aws`. It matches text, so it stops the agent reaching for the host's keys by habit, not a determined one; the scrub above is what keeps them out by default.

`HOME` is left alone: Claude Code reads its login and settings from it.

Run `htr.py preflight --agent` to see this from inside a launched agent: it prints which `AWS_*` names the agent has, what `aws sts get-caller-identity` returns, and whether its `cat ~/.aws/credentials` was denied.

## The principal (vibeset-dj)

The account already runs agents under `vibeset-dj-agent` with the permissions boundary `vibeset-dj-agent-boundary` (appendix 10, `docs/spec/10-infra-and-iam.md`; the GitHub deploy role carries the same boundary, `docs/deploy.md`). Ticket agents get their own user, so their key can be rotated or revoked without touching the milestone agents, and its policy is scoped to what a build ticket does: invoke Bedrock to re-record fixtures, read the model-weights bucket, read the service's logs and configuration. Deploys stay with the CI deploy role; Terraform applies stay with the owner.

[`templates/aws-agent-policy.json`](templates/aws-agent-policy.json) is the identity policy. It allows only those reads and the Bedrock invokes, and denies, explicitly and whatever else is attached later: every `iam:*` and role assumption, every deploy or infrastructure write, every Secrets Manager, KMS-decrypt and Parameter Store read, and anything not on its own allow list. It passed IAM Access Analyzer `validate-policy` with no findings on 2026-10-24. At about 3.3 KB minified it is too large for an inline user policy (2048 characters), so it goes in as a managed policy.

## Checklist

Each step is run by the owner with admin credentials, from a shell that is not a ticket agent.

1. **Read the policy** and narrow it if a ticket class needs less: the Bedrock resources can be cut to the model families in appendix 08, and `ReadOwnLogs` and `DescribeOwnService` dropped if agents never debug the deployed service. Widen it only by a statement you could name a ticket for.
2. **Create the managed policy:**
   ```
   aws iam create-policy --policy-name vibeset-dj-ticket-agent \
     --policy-document file://templates/aws-agent-policy.json \
     --description "host-ticket-runner agents: Bedrock invoke and read-only service access"
   ```
3. **Create the user with the boundary on it**, so the user can never exceed the agent boundary even if a broader policy is attached by mistake:
   ```
   aws iam create-user --user-name vibeset-dj-ticket-agent \
     --permissions-boundary arn:aws:iam::887324280633:policy/vibeset-dj-agent-boundary \
     --tags Key=project,Value=vibeset-dj Key=purpose,Value=host-ticket-runner
   aws iam attach-user-policy --user-name vibeset-dj-ticket-agent \
     --policy-arn arn:aws:iam::887324280633:policy/vibeset-dj-ticket-agent
   ```
   The name carries the `vibeset-dj-` prefix the boundary and appendix 10's deny statements key on.
4. **Create the key and install it straight into the runner**, never through a file, a chat or an argument:
   ```
   aws iam create-access-key --user-name vibeset-dj-ticket-agent | htr.py aws-keys
   ```
   `aws-keys` reads the JSON from stdin, writes `HTR_HOME/aws/credentials` with mode 600 and prints only the key id.
5. **Check it from inside an agent:** `htr.py preflight --agent`. Done when the caller identity is `arn:aws:iam::887324280633:user/vibeset-dj-ticket-agent`, the agent's `AWS_*` names are only the five the runner sets, and the `~/.aws` read is denied.
6. **Check the denies hold:** with the runner's profile (`AWS_CONFIG_FILE=... AWS_SHARED_CREDENTIALS_FILE=... AWS_PROFILE=htr-agent`), `aws iam list-users` and `aws secretsmanager list-secrets` must both return `AccessDenied`.
7. **Rotate** every 90 days, or at once if a run log ever shows the key: create a second key, install it with step 4, then `aws iam delete-access-key --user-name vibeset-dj-ticket-agent --access-key-id <old id>`.

Another repository follows the same steps with its own prefix, boundary and resources in the policy template.

## What stays out of reach

- A repo's own `.env` can re-introduce keys: vibeset-dj's justfile loads `.env` (`set dotenv-load`), and a recipe would then run with whatever key the file holds. A fresh worktree has no `.env`; do not copy one holding owner-level keys into a run's worktree.
- An MCP server configured with its own AWS environment (an `env` block naming a profile) runs with that, not the runner's. Profiles it names do not exist in the runner's config file, so its calls fail rather than reach the host's keys, unless its block also sets `AWS_CONFIG_FILE`.
- No sandbox: a process the agent starts can read any file the owner's user can. A separate OS user for the runner is the step that closes this, and it is not taken here.
