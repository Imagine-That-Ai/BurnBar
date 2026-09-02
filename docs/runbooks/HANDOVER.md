# Operator handover

This is the public handover skeleton for OpenBurnBar. It records ownership and
verification slots without storing credentials, recovery codes, private keys,
tokens, or personal device identifiers. Put secrets in the approved provider
vaults and link the access procedure here after a human owner confirms it.

**Schema status:** every required slot is populated or explicitly `UNSET`.
**Last schema review:** 2026-09-01.

## Required slots

| Slot | Value | Scope |
| --- | --- | --- |
| Primary operator | UNSET | Release, production, and emergency approval |
| Backup operator | UNSET | Independent second-person coverage |
| Release approver | UNSET | macOS, iOS, Android, Windows, and Linux release decisions |
| Security incident owner | UNSET | Vulnerability triage and disclosure coordination |
| Production deploy approver | UNSET | Firebase, GCP, hosted services, and rollback authority |
| Emergency communications owner | UNSET | User-facing incident updates and status communication |
| Next handover date | UNSET | Human-confirmed transfer checkpoint |

## Transfer checklist

1. Confirm the primary and backup operators are distinct people.
2. Review the access inventory and replace each applicable `UNSET` with an
   owner or approved group, never with a credential.
3. Run the relevant release, deploy, and rollback verification commands from
   their committed runbooks.
4. Record the date and approver in the private operational log; do not add
   private incident details to this public document.

## Escalation

- A missing owner blocks the corresponding release or production action.
- A suspected credential exposure pauses the affected action and follows
  `SECURITY.md`; do not paste the secret into an issue, PR, or this runbook.
- If both human operators are unavailable, leave the slot `UNSET` and escalate
  through the repository's protected ownership channel rather than inventing a
  bypass.
