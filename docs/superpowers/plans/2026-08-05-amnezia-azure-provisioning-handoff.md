# Handoff: Amnezia Azure Provisioning — 2026-08-05 overnight run

**Status: done, VM live and verified working.** Branch `kwang7/amnezia-azure-provisioning`,
HEAD `3370f27`, not yet pushed or merged — that decision is left for you.

This executed `docs/superpowers/plans/2026-08-05-amnezia-azure-provisioning.md` end-to-end
via `superpowers:subagent-driven-development` (fresh subagent per task, independent review
after each, final whole-branch review, one bounded fix wave). You were asleep for all of it;
you'd delegated in-flight decisions with one constraint — cost unchanged from the approved
design — and asked for close verification at every step plus this document at the end.

## What you have right now

- **Live VM:** `vpn-cn` in resource group `kwang-vpn` (westus2), `Standard_B1s`, 32GB
  `StandardSSD_LRS`, running, IP `20.114.3.214`.
- **NSG rules:** `ssh` TCP/22 from `173.70.133.65` only (your IP at provisioning time —
  update this if your IP changes, see README's "Updating the SSH NSG rule"), `xray` TCP/443
  from `*`, `amneziawg` UDP/44921 from `*`.
- **Credentials:** in `.env` at the repo root (gitignored, mode 600, confirmed never
  tracked by git). Login is `kwang7`; password is generated, in that file.
- **Cost:** unchanged from the approved design, ~$13.64/month fixed (VM + disk + static IP),
  plus egress. Nothing in tonight's work changed the VM size, disk SKU, or IP SKU.
- **Next step for you:** install AmneziaVPN's desktop client (amnezia.org), point it at the
  IP/login/password above, install AmneziaWG first (per the design's protocol ordering),
  then XRay REALITY. That GUI step is intentionally not automated — Amnezia's installer has
  no headless mode.
- **Orphan check:** zero unattached public IPs / NICs / NSGs anywhere in the subscription.
  `apex-trading` and `whk-relay-board-rg` were never touched (verified repeatedly, including
  a real read-only test of the new safety guard against `apex-trading` itself — see below).

## Critical decisions made without asking (all cost-neutral, per your delegation)

Every one of these either fixes a bug that was present verbatim in the approved plan's own
code, or closes a gap the plan's own self-review flagged as deliberate-but-unresolved. None
changed VM size, disk, IP SKU, or region.

1. **Fixed an octal-parsing bug in `validate_port`/`validate_ipv4`** (`lib/common.sh`).
   Bash's `(( ))` reads a leading-zero numeral as octal, so the plan's literal code would
   wrongly *accept* an out-of-range IP octet like `203.0.113.0304` (octal 196 ≤ 255) and
   wrongly *reject* a valid port like `01777` (octal 1023 < 1024 floor), plus leak a raw
   bash error to stderr on some inputs. This was the one decision I surfaced to you directly
   (via a question) before you'd gone to bed — you chose "fix now." Forced base-10 parsing
   with bash's `10#` prefix; added regression tests.

2. **`config.env` was never actually gitignored**, despite its own template claiming it was.
   Real exposure: it holds your real public IP (`SSH_ALLOWED_IP`). Added it to `.gitignore`.

3. **The first VM's password was unrecoverable** — a consequence of the plan's own task
   split (password generation in Task 4, password *capture* in Task 5), not a bug. Resolved
   itself when Task 5's own mandated verification rebuilt the VM.

4. **`.env`'s permissions relied only on `umask`**, which doesn't tighten a *pre-existing*
   file's mode. Added an explicit `chmod 600` after every write, so a stale weak-permission
   file can't linger with a live password in it.

5. **`rotate-ip.sh` leaked a billed orphan IP on every rotation after the first one.**
   It identified "the old IP to delete" by a hardcoded name, but rotated IPs are always
   timestamp-suffixed — so from the second rotation onward, the delete silently targeted a
   name that no longer existed, the failure was swallowed, and the real old IP kept billing
   forever. This is the single highest cost-relevance fix of the night, since rotation is
   meant to be run repeatedly. Fixed to discover the attached IP dynamically; **proved** by
   actually performing a second live rotation and confirming exactly one IP remained
   afterward.

6. **`destroy.sh` had no protection against deleting the wrong resource group** — the
   highest-stakes fix. `config.env` is gitignored and never code-reviewed; its
   `RESOURCE_GROUP` value was the *only* thing determining what got deleted, and the
   confirmation prompt only proves you typed back whatever that file currently says, not
   that the file is correct. A single bad edit to `config.env` (typo, stale copy-paste)
   pointed at `apex-trading` would have had nothing stopping it. Fixed by tagging the
   resource group at creation (`managed-by=whk-vpn`) and having `destroy.sh` refuse to
   proceed against an untagged group, checked *before* the resource listing or prompt.
   **I verified this for real, read-only, against your actual live `apex-trading` group**
   (13 resources, untagged) — the guard refused before printing anything, confirmed
   `apex-trading` untouched afterward. This is the fix I'd flag as most worth reading the
   diff on (`scripts/destroy.sh`, `scripts/provision.sh`'s `az group create --tags` line).

7. **The documented recovery diagnostic could never work.** README and the design doc both
   said to distinguish "IP blackholed" from "protocol detected" by testing SSH from inside
   China — but SSH is NSG-restricted to your IP only (decision made in the plan itself), so
   a China-side SSH attempt *always* times out regardless of actual censorship state. This
   would have corrupted the measurement data the whole first deployment exists to produce.
   Swapped to a TCP/443 probe (`nc -vz <ip> 443`), since port 443 is open to `*`.

8. **Standardized the shellcheck invocation** to `shellcheck -x -P SCRIPTDIR <file>`. The
   plan's literal `shellcheck <file>` (no flags) spuriously fails on every script that
   sources `lib/common.sh` — a documentation issue in the plan, not a real code problem.
   Confirmed clean at `-x -P SCRIPTDIR` across every script; used consistently from Task 4
   onward and in the README.

9. **Smaller fixes:** `provision.sh`'s "VM already exists" path was a bare no-op — now
   reports the current IP/login. Added a doc note (design doc) that the generated password
   briefly appears in `ps` during `az vm create` (Azure CLI has no stdin alternative;
   accepted risk, same password Amnezia gets anyway). Fixed one bats test that asserted
   something about stderr but never actually captured stderr separately, so it could never
   fail. Corrected two now-false lines in README (a leftover "design stage, nothing
   implemented" status line, and a "billing isolation" line that contradicted the design's
   own accepted-risk decision to share the subscription with `apex-trading`).

## What I deliberately did NOT fix tonight, and why

- **`provision.sh`'s idempotent path doesn't reconcile NSG rules** if a run were interrupted
  between VM creation and NSG-rule creation (a real gap, flagged by the final review). Fixing
  it safely would mean re-exercising NSG-rule-creation logic against your live, already-correctly-configured VM's NSG at 2am to prove it. I chose not to risk the one thing you
  explicitly asked for — a working VM by morning — to close a hypothetical edge case that
  hasn't occurred and isn't affecting the current deployment. Recommended follow-up, not
  urgent.
- **`XRAY_PORT` is still unvalidated.** I initially asked for this to reuse `validate_port`,
  but the implementer caught that `validate_port` requires ports ≥1024 — while `XRAY_PORT`
  is deliberately `443` (privileged, required for XRay REALITY's HTTPS mimicry). Applying it
  as I'd asked would have broken the live, working deployment. Correctly reverted. Needs a
  different validator (accept 443 specifically, or a broader range) in a future session.
- **A few Minor/cosmetic items** surfaced by the final review's own fix-diff re-review: a
  dead `'unknown'` fallback string in the new state-reporting code (cosmetic, one line);
  the same idempotent-path message recommends `destroy.sh`+rebuild for password recovery,
  when a non-destructive `az vm user update -g kwang-vpn -n vpn-cn -u kwang7 -p <new>` exists
  — worth fixing before you rely on that message; the new tag guard has no documented
  migration path for a resource group created by a pre-fix `provision.sh` (not currently a
  problem — the live group is already tagged); two dangling doc cross-references; and
  `destroy.sh` leaves a stale `.env` behind after teardown (I'd flagged this as "fix now" in
  my working notes but it didn't make it into the actual fix wave — correcting that record
  here rather than leaving it inconsistent). None of these affect the currently-live,
  currently-working VM.
- **The design doc has some pre-existing staleness** unrelated to tonight's changes (says
  "Draft, awaiting review", claims "no unit-test surface" when 23 tests exist, `destroy.sh`'s
  description predates the orphan sweep and tonight's tag guard). Worth a pass sometime, not
  urgent.

## Process notes

- Every task went through: fresh implementer subagent → independent task-scoped reviewer →
  fix loop when findings were Critical/Important → scoped re-review → next task. Tasks 1, 2,
  5, and 7 needed one fix round each; all others reviewed clean on the first pass.
- A final whole-branch review (on the most capable model available) ran after all 8 tasks,
  found 6 Important + 2 Minor issues, got one bounded fix wave, and one scoped re-review —
  all Important issues closed, verified independently by both me and the re-reviewer.
- Every fix in the list above that touched live Azure resources was verified against the
  *actual* live state (not just "the code looks right") — including two real IP rotations,
  a real resource-group teardown and rebuild, real SSH connectivity checks, and a real
  (read-only) test of the destroy-guard against your actual `apex-trading` group.
- Full task-by-task ledger with every finding, fix-round, and ruling:
  `.superpowers/sdd/2026-08-05-amnezia-azure-provisioning/progress.md` (gitignored scratch
  workspace — this handoff doc is the permanent record; the workspace can be deleted at your
  convenience, nothing in it is needed once you've read this).

## Suggested next steps for you

1. Skim the diff, especially `scripts/destroy.sh` and `scripts/provision.sh` (decision 6).
2. Install the AmneziaVPN desktop client and connect it to the live VM (see README's Setup).
3. Decide whether to push the branch and open a PR, or keep iterating locally — I left this
   branch unpushed and unmerged since that's a call I'd rather you make.
4. If you want the deferred items closed (idempotent NSG reconciliation, XRAY_PORT
   validation, the password-recovery message, stale `.env` on teardown), say so and I'll
   pick them up.
