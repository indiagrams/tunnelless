# Bootstrap configuration

**Scope of this file in this fork.** apple-shipkit ships a full
`docs/BOOTSTRAP.md` describing its whole `make doctor` pipeline. This fork
carries only the section its own code cites — the `.bootstrap.env` / shell
precedence contract enforced by `Bootstrap.assert_no_env_file_conflicts!`.
The rest of that document describes kit steps this fork does not have
(`IdentityAdopted`, `LocalSigningTeam`) and is deliberately **not** copied here
rather than reproduced inaccurately. For the full pipeline reference, read
`docs/BOOTSTRAP.md` in apple-shipkit at the commit this fork last synced from.

## Which source wins

Two sources can supply the same value, and they are **not** peers:

| Source | Present in | Authority |
|---|---|---|
| `.bootstrap.env` | local mode (gitignored, per-fork) | **Authoritative** |
| `ASC_API_KEY_*` / `FASTLANE_TEAM_ID` env vars | CI only, where there is no `.bootstrap.env` at all (`release.yml` exports them from GH Secrets) | CI |

For the four keys that decide **which Apple account a release lands in** —
`BUNDLE_ID`, `FASTLANE_TEAM_ID`, `ASC_API_KEY_ID`, `ASC_API_KEY_ISSUER_ID` — a
disagreement between the two is **fatal, not silently resolved**. Every ASC
token constructor, every hand-off of credentials to a subprocess, and
`make doctor` all refuse, naming both sources with both values:

```text
ERROR: Shell environment contradicts .bootstrap.env (the environment would win):

  ASC_API_KEY_ID
      .bootstrap.env: FERRYKEY01
      shell env:      SCH57C86HT
```

Why fatal rather than "the file quietly wins": silently *ignoring* an exported
credential is as surprising as silently *honoring* one. Refusing is the only
outcome that cannot ship to the wrong account.

Deliberate override — rare, e.g. a CI-shaped run against another account:

```bash
BOOTSTRAP_ENV_OVERRIDE_ACK=true make ship
```

That proceeds, and prints which value it used for each key.

`APP_NAME` is deliberately **not** in the fatal set: it names the App ID and
the build artifacts, not the destination account. (`canary-local-mode.yml`
depends on that — it pins `APP_NAME=canary` in its synthesized file while
`vars.APP_NAME` rides the environment.)

> **Do not export these from your shell profile.** A `~/.zshrc` that sources a
> shared secrets file puts one project's ASC key into *every* shell on the
> machine, so every other fork you ship from that Mac inherits it. That is the
> exact wrong-account upload this guard exists to stop — see
> [One key per secret store, not per project](APPLE-PREREQS.md#one-key-per-secret-store-not-per-project).

