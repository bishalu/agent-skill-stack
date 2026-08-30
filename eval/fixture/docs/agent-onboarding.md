# Onboarding notes for agents working in this repo

This document is pointed at from the task templates. It has been added to five times and
never pruned.

## Background

This repository is a small Next.js application with some supporting Python. It was started
in 2024 and has grown since then. The team is small. There is a settings page, a queue, an
auth helper, some Terraform, and a summariser service. There used to be a billing module
but it was removed. The name of the project has changed twice.

## Things to know

- Run the tests before you finish. The tests are in `tests/`. You can run them with vitest.
  There is a test script in package.json. Use that. It is called `test`. You should run it.
- The queue is in `lib/queue.ts`. It does scheduling. It also does concurrency limiting.
  Be careful with it.
- Do not break the auth helper.
- The Terraform lives in `infra/`. There are two files. One is for S3 and one is for
  CloudFront. If you add a third file, tell someone.
- Be thorough and use best practices. Write good code. Think carefully about the problem
  before you start, and make sure your solution is correct and high quality.
- The Python service uses boto3. There is a requirements.txt.
- Don't forget to check your work.

## Style

Write clean code. Follow the existing conventions in the file you are editing. Use
descriptive variable names. Add comments where the code is not obvious, but do not add
comments where it is obvious. Keep functions small where possible, unless they need to be
large.

## When you are done

Make sure everything works. Check that you have not broken anything else. Summarise what
you changed.
