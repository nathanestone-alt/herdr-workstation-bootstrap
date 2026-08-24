# Host commissioning kit for STModel-Private #957

This directory contains runnable, user-gated commissioning legs. It does not
commission a host by itself and it never creates a credential file or touches
GitHub.

The existing merged implementation is intentionally reused:

- scripts/windows/New-HerdrExchangeShare.ps1 creates or validates the dedicated
  non-admin HerdrBridge identity, creates the encrypted share, protects
  C:\HerdrTools and C:\HerdrReviewJobs, and installs the exact Tailscale-scoped
  firewall rule.
- scripts/windows/Test-HerdrExchangeBoundary.ps1 runs the negative ACL probe
  and reviews active conflicting SMB rules by exact rule name.
- scripts/ubuntu/configure-excel-share.sh prompts for the bridge credential
  without accepting it on the command line, proves an isolated SMB write, and
  installs a root-owned mode-0600 credential file plus the managed fstab
  automount entry.
- scripts/windows/Stage-HerdrReviewWorkbook.ps1 and
  scripts/windows/Invoke-HerdrExcelJob.ps1 are the production staging and
  Excel entry points; their default-deny and provenance behavior is exercised
  by the commissioning roundtrip wrapper.

New legs in this kit:

- ubuntu/check-herdr-exchange-mount.sh verifies credential metadata,
  fstab/source/options, mount ownership, and a disposable write/remove probe.
- ubuntu/check-herdr-exchange-reconnect.sh tests the fstab automount reconnect
  only after explicit disruption confirmation.
- ubuntu/capture-herdr-commissioning-evidence.sh writes a new local 0600
  commissioning record outside the repository and exchange.
- ubuntu/test-password-hygiene.sh scans user-selected evidence and Git diffs
  without printing the password.
- windows/Test-HerdrOneDriveHydration.ps1 proves the designated interactive
  OneDrive account and rejects Offline/Recall attributes.
- windows/Test-HerdrExcelComSmoke.ps1 creates only a disposable temp workbook
  and records the default-deny smoke settings.
- windows/Invoke-HerdrReviewCommissioningRoundtrip.ps1 runs the production
  Inbox -> staging -> protected review-job copy -> Outbox path and compares
  hashes, provenance, security fields, and byte-identical manifests.

Follow the complete acceptance map in docs/issue-957-commissioning-checklist.md
in order. Ubuntu privileged steps and every Windows step are user actions.
