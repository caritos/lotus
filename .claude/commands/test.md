---
description: Run the fast test tier and summarise failures
---

Run `make test-fast` from the repository root (Go `-short` tests, Vitest and the TypeScript typecheck).

Then report:
- pass or fail per step (Go, web tests, typecheck);
- for each failure, the package or file, the test name and the first useful error line;
- a one-paragraph guess at the cause if it is obvious from the output.

Do not edit any code unless I ask you to. If `pnpm` is not found, say that Node 24 with corepack is required (see `.nvmrc`) instead of working around it.
