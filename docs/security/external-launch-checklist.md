# RIMS External Launch Checklist

Status: OPEN EXTERNAL

This checklist separates locally executable M12 controls from actions that need
production accounts, legal authority, independent assessors, or organizational
approval. Local substitutes prove contract shape and failure behavior only.
They cannot close an external row or be reported as production evidence.

| ID | Launch action | Owner | Required evidence | Local substitute | Status |
| --- | --- | --- | --- | --- | --- |
| `external.dns_tls` | Production domain, DNS, CA-issued certificate, load balancer/proxy trust, renewal, HTTPS redirect, HSTS, and optional preload decision | Platform/SRE owner | DNS records; certificate chain and private-key custody reference; approved proxy CIDRs; external HTTPS scan; renewal alert test; redirect/HSTS observation; preload decision | Managed workspace CA and HTTPS proxy test trusted path, direct HTTP rejection, spoofed-forwarded-header rejection, wrong-host/untrusted/expired-certificate rejection, and exact cleanup | OPEN EXTERNAL |
| `external.secret_custody` | Production JWT, refresh-token pepper, data-encryption, TOTP, database, certificate, signing, and recovery secret custody | Security and Platform owners | Secret-manager object inventory; least-privilege access review; generation provenance; rotation/rollback drill; escrow/recovery approval; access audit; no repository/default secret scan | Injected local keys under ignored `.runtime`; fail-closed short/default-secret tests; safe configuration summary; secret scanner fixtures without real values | OPEN EXTERNAL |
| `external.database_tls_backup` | Production database TLS identity, encryption at rest, encrypted backups, restore, retention, deletion, residency, and provider access | Database/Platform owner | Verified server identity and TLS policy; encryption configuration; backup schedule and key owner; successful restore drill with RPO/RTO; retention/deletion evidence; residency and subprocessor approval | Local PostgreSQL TLS-policy tests; deterministic backup/restore contract fixtures; migration repeat tests; backup exclusion inventory; no claim of production durability | OPEN EXTERNAL |
| `external.legal_privacy` | Privacy notice, terms, lawful basis, processor/subprocessor list, permission purposes, retention, account export/deletion, data-subject process, and cross-border review | Legal/Privacy owner | Approved dated documents; release locale/version; processor agreements; data-flow and retention signoff; export/deletion response procedure; Android store privacy declarations | Locally testable permission/provider/data-class inventories; allowlisted export and deletion procedure tests; draft notices clearly marked unapproved | OPEN EXTERNAL |
| `external.penetration_test` | Independent production-scope penetration test and security risk acceptance | Independent security assessor and risk owner | Signed scope and rules of engagement; tested release identities; authenticated and unauthenticated results; remediation evidence; retest; residual-risk acceptance; open P0/P1 count zero | Local SAST, dependency, secret, authorization, replay, abuse, TLS, route, APK, and redaction gates with synthetic attack fixtures | OPEN EXTERNAL |
| `external.android_release` | Android signing identity, key custody, Play Integrity/provider activation, anti-debug policy, store data-safety/account-deletion declarations, and store review | Mobile release owner and Security owner | Signed release artifact hash; signing-certificate fingerprint; key custody/rotation evidence; integrity project/config and verdict test; manifest/APK inspection; approved store declarations; review result | Locally signed debug/release builds; provider interfaces with deterministic fakes; manifest/APK tests for permissions, cleartext, backup, screenshot, and bypass policy | OPEN EXTERNAL |
| `external.incident_response` | Security monitoring, on-call ownership, session/key revocation, containment, forensics, breach assessment/notification, support verification, and exercises | Security incident commander and Operations owner | Approved runbook; severity/contact matrix; alert routes; access/revocation procedures; evidence-preservation rules; tabletop record; notification decision tree; post-incident owner | Synthetic refresh reuse, lockout, revocation, audit, redaction, key-loss, and cleanup exercises with no production notification claim | OPEN EXTERNAL |
| `external.rollout_approval` | Final production change, migration, capacity, rollback, support, security, privacy, and business release approval | Release manager with Engineering, Security, Privacy, Operations, and Business approvers | Tested frontend/backend commit and artifact hashes; all local gates; external checklist closures; defect/risk register; migration/rollback rehearsal; monitoring and support readiness; signed go/no-go record | Stopped-state M9-M12 local regression, deterministic fixture restore, exact process cleanup, defect audit, and dry-run rollout checklist | OPEN EXTERNAL |

## Closure Rules

1. Only the named owner or formally delegated approver may close a row.
2. Closure replaces `OPEN EXTERNAL` with an approval date and immutable evidence
   reference. Secret values, private keys, credentials, and personal data are
   never embedded in this repository.
3. A local substitute may remain green while external evidence is absent; it
   does not change the row status.
4. A changed production provider, domain, signing identity, data purpose,
   permission, or release artifact reopens the affected approval.
5. M12 local completion links this checklist and leaves every unresolved row
   `OPEN EXTERNAL`; no automated worker may translate it to `PASS`.
