# STModel-Private #957 host commissioning checklist

This is the user-run commissioning gate for the bridge merged in bootstrap
PR#3 and STM PR#966. It is deliberately ordered: Windows security and
interactive prerequisites come first, then the Ubuntu mount, then the
end-to-end disposable roundtrip. The kit never posts evidence to GitHub.

The only credential allowed in this workflow is the user-supplied HerdrBridge
password held in the approved password manager and, on Ubuntu, the
root-owned mode-0600 credential file at the configured path. Do not pass it as
a command argument, put it in shell history, echo it, or place it in a
manifest, log, Git diff, OneDrive file, or commissioning record.

## Acceptance map

| #957 acceptance checkbox | Satisfying step | Who runs it | Evidence to retain |
| --- | --- | --- | --- |
| C-01: Work from the reviewed implementation and commissioning branch | Confirm the branch is based on 6495aae6b5fb41fff8ac04a4943001599a24435d; this worker commit is recorded in the return artifact | automated/static | branch name and commit SHA |
| C-02: HerdrBridge is a dedicated enabled non-admin identity | Run scripts/windows/New-HerdrExchangeShare.ps1 with its interactive password prompt; do not use Administrator or supply a password argument | user-Windows | exact LocalUser/SID, enabled state, and direct group membership |
| C-03: The Windows exchange share is encrypted | The same existing share script must create or converge HerdrExchange with EncryptData true and AccessBased enumeration | user-Windows | Get-SmbShare output showing path, encryption, and access mode |
| C-04: SMB exposure is Tailscale-scoped | Review the exact rule Herdr Exchange SMB over Tailscale: inbound TCP 445, remote 100.64.0.0/10 and fd7a:115c:a1e0::/48 | user-Windows | exact rule name, protocol/port, profiles, and remote ranges |
| C-05: No unreviewed conflicting SMB firewall rule remains | The existing share script and boundary test enumerate active inbound allow rules; any exception must be passed by exact rule name and recorded | user-Windows | conflict listing and named user-approved exception, if any |
| C-06: Host-owned reviewed tools are protected | New-HerdrExchangeShare.ps1 converges C:\HerdrTools outside the share with the host-owned ACL policy | user-Windows | ACL/effective-access evidence for C:\HerdrTools |
| C-07: Host-owned Excel review jobs are protected | New-HerdrExchangeShare.ps1 converges C:\HerdrReviewJobs outside the share with the host-owned ACL policy | user-Windows | ACL/effective-access evidence for C:\HerdrReviewJobs |
| C-08: Bridge write boundary is negative-tested | Run scripts/windows/Test-HerdrExchangeBoundary.ps1; HerdrBridge must fail at the share root, legacy scripts root, tools root, and review-jobs root, while writing only the allowed exchange input | user-Windows | boundary PASS and exit code 0 |
| C-09: Ubuntu credential is root-owned and mode 0600 | Run scripts/ubuntu/configure-excel-share.sh; it prompts interactively, proves an isolated SMB write, and installs the credential file only after that proof | user-sudo-Ubuntu | credential path plus stat uid=0,gid=0,mode=600; never the file contents |
| C-10: Ubuntu mount uses the reviewed secure options | The managed fstab entry and check-herdr-exchange-mount.sh must show cifs, vers=3.1.1, seal, uid/gid ownership, 0660/0770 modes, _netdev, nofail, and x-systemd.automount | user-sudo-Ubuntu | local mount record and sanitized findmnt options |
| C-11: Ubuntu ownership/write behavior works | Run check-herdr-exchange-mount.sh; it creates and removes a disposable input probe as the configured owner | user-sudo-Ubuntu | PASS line with owner UID/GID and write_test=PASS |
| C-12: Reconnect behavior is proven | During a reviewed maintenance window run check-herdr-exchange-reconnect.sh --confirm-disruption; it unmounts, triggers automount on access, and repeats the write probe | user-sudo-Ubuntu | reconnect PASS and the maintenance timestamp |
| C-13: Ubuntu host evidence is captured locally | Run capture-herdr-commissioning-evidence.sh with a new output path outside Git and outside the SMB mount | user-sudo-Ubuntu | mode-0600 herdr-ubuntu-commissioning-v1 record |
| C-14: OneDrive is running under the designated interactive identity | Set the host-owned runtime config outside Git with the exact account, user SID, session ID, and bridge SID; Test-HerdrOneDriveHydration.ps1 calls the production identity/readiness gates | user-Windows | hydration JSON with account, identity, session, and exchange roots |
| C-15: OneDrive exchange paths are hydrated | In Explorer select Always keep on this device for the exchange, Inbox, Outbox, Archive, and disposable source; the hydration script rejects Offline and Recall attributes | user-Windows | hydration JSON plus manual Explorer checkpoint |
| C-16: Excel COM works on a disposable payload | Run Test-HerdrExcelComSmoke.ps1; output must remain under the Windows temp directory and never be the canonical workbook | user-Windows | smoke JSON, temp output hash, and canonical_workbook_mutated=false |
| C-17: Excel automation remains default-deny | The production runner must record macros=disabled, external_links=not-updated, data_connections=disabled, trusted_locations=none-added | user-Windows | result provenance manifest security object |
| C-18: Inbox source is staged without mutation | Put only the disposable fixture in the configured OneDrive Inbox and run Invoke-HerdrReviewCommissioningRoundtrip.ps1; staging must preserve the source and match its SHA-256 | user-Windows | staging-provenance.json and roundtrip JSON |
| C-19: Protected job copy and Outbox result complete | The same wrapper invokes the production Excel job wrapper, which copies into the protected review-job root and then to local and OneDrive Outbox | user-Windows | runner result JSON, result file hash, and Outbox paths |
| C-20: Provenance manifests compare exactly | The wrapper compares source/stage/result hashes, repository/branch/commit provenance, and byte-identical local versus OneDrive provenance.json | user-Windows | PASS roundtrip JSON and both manifest paths |
| C-21: Fixture is noncanonical and disposable | Use fixtures/commissioning/disposable-workbook/README.md generation instructions; use no STModel workbook and do not commit generated files | user-Windows | fixture path, hash, and cleanup confirmation |
| C-22: Password-leak negative test passes | Run fixtures/commissioning/password-leak-negative/README.md self-test, then pipe the approved password-manager value to ubuntu/test-password-hygiene.sh over all relevant evidence paths | user-sudo-Ubuntu | PASS hygiene output; no password value in captured stdout/stderr |
| C-23: Manual gates are explicitly acknowledged | Record credential supply, Windows interactive login/session, exact firewall review, OneDrive hydration, and final evidence review before enabling approved in the host-owned runtime config | user-Windows / user-sudo-Ubuntu | signed or ticket-linked commissioning record |
| C-24: Evidence is posted only by the user | Review the local records and post the approved evidence to STModel-Private #957 manually; no worker or script invokes GitHub | user gate | issue comment URL supplied by the user |

## Ordered runbook

### 1. Prepare Windows configuration without committing it

Copy config/windows-review-runtime.example.json to a host-owned Windows path
outside Git. Fill in the real OneDrive root/account, local exchange root,
review-jobs root, tools root, designated interactive SID/session, and
HerdrBridge SID. Keep approved false until every step passes; the production
wrappers fail closed when the config is absent, malformed, unapproved, or
overlapping.

### 2. Converge the Windows identity, share, ACLs, and firewall

From an elevated PowerShell session on the Windows host, run:

~~~powershell
pwsh -NoProfile -File scripts/windows/New-HerdrExchangeShare.ps1
pwsh -NoProfile -File scripts/windows/Test-HerdrExchangeBoundary.ps1
~~~

The first command prompts for the bridge password. Supply it from the
approved password manager only. Do not use -Password on the command line.
Review every firewall conflict by exact rule name; do not use a wildcard
exception. The boundary command must be run as a separate verification and
must finish with exit code 0.

### 3. Verify OneDrive identity and hydration

Sign in to the designated interactive Windows session and confirm the native
OneDrive client is running under the configured account. In Explorer choose
Always keep on this device for the exchange root, Inbox, Outbox, Archive, and
the disposable source workbook. Then run:

~~~powershell
pwsh -NoProfile -File scripts/commissioning/windows/Test-HerdrOneDriveHydration.ps1 -RuntimeConfigurationPath C:\Path\To\host-owned-runtime.json -WorkbookPath '<configured Inbox>\commissioning-fixture.xlsm' -EvidencePath C:\Path\To\local\hydration.json
~~~

The script must return schema herdr-onedrive-hydration-v1 and status PASS. The
manual Explorer action is still a checkpoint; absence of Offline/Recall
attributes is its machine-readable proof.

### 4. Generate and retain only a disposable Excel fixture

Run Test-HerdrExcelComSmoke.ps1 with -KeepOutput, or follow the generation
instructions in fixtures/commissioning/disposable-workbook/README.md. Copy the
result into the configured OneDrive Inbox using a user-controlled Windows copy
step. Do not open or copy the STModel canonical workbook.

### 5. Run the full Windows roundtrip

Use a new collision-free job ID and the actual reviewed repository provenance:

~~~powershell
pwsh -NoProfile -File scripts/commissioning/windows/Invoke-HerdrReviewCommissioningRoundtrip.ps1 -RuntimeConfigurationPath C:\Path\To\host-owned-runtime.json -SourcePath '<configured Inbox>\commissioning-fixture.xlsm' -JobId commissioning-20260824-001 -Repository STModel-Private -Branch '<reviewed source branch>' -Commit '<reviewed source commit>'
~~~

The script has no TestMode switch. It uses the production staging and Excel
wrappers, checks the protected last-mile copy, and compares local/OneDrive
provenance manifests. Preserve the JSON output and the generated paths for
the user evidence review.

### 6. Prepare and verify the Ubuntu mount

After the Windows share is ready, the user runs the existing prepare leg:

~~~bash
sudo bash scripts/ubuntu/configure-excel-share.sh
bash scripts/commissioning/ubuntu/check-herdr-exchange-mount.sh
~~~

The configure script prompts for the same approved password and never accepts
it as a command-line value. The check script reads only credential metadata;
it never reads the credential file contents.

During a reviewed maintenance window, prove reconnect:

~~~bash
bash scripts/commissioning/ubuntu/check-herdr-exchange-reconnect.sh --confirm-disruption
~~~

Capture the local record outside the repository and outside
/srv/herdr-exchange:

~~~bash
bash scripts/commissioning/ubuntu/capture-herdr-commissioning-evidence.sh --output /tmp/herdr-commissioning-record-20260824.txt --run-reconnect --confirm-disruption
~~~

If the output says FAIL, the record is still evidence of the failed
precondition and must not be represented as a commissioning PASS.

### 7. Prove password hygiene

Run the synthetic fixture first. For the live check, provide exactly one line
from the approved password manager to stdin and scan the Ubuntu record, every
staging/result manifest, every job log, and the OneDrive Outbox evidence
directory. Do not substitute a shell variable populated from command history
or place the value in a command argument:

~~~bash
approved-password-manager-command |
  bash scripts/commissioning/ubuntu/test-password-hygiene.sh \
    --repo "$PWD" \
    --scan /tmp/herdr-commissioning-record-20260824.txt \
    --scan /path/to/reviewed/staging-provenance.json \
    --scan /path/to/reviewed/provenance.json \
    --scan /path/to/reviewed/job.log \
    --scan /path/to/OneDrive/Outbox/commissioning-20260824-001
~~~

The placeholder approved-password-manager-command is intentionally not a
real command. The user must substitute the approved password manager’s
non-echoing export mechanism. The scanner prints only a generic PASS/FAIL and
never prints the supplied value.

### 8. Close the user gate

The user reviews the branch commit, static checks, Windows and Ubuntu records,
fixture hash, manifest comparison, and the password-hygiene result. Only the
user may set approved true in the host-owned runtime config or post evidence
to STModel-Private #957. The worker does not touch GitHub, hosts, Windows
sessions, sudo, mounts, credentials, or the canonical workbook.

## Evidence schema references

- Ubuntu record: herdr-ubuntu-commissioning-v1, line-oriented and mode 0600.
- OneDrive hydration record: herdr-onedrive-hydration-v1.
- Staging manifest: herdr-review-staging-v1.
- Excel result provenance: herdr-excel-job-result-v1.
- Example shape: fixtures/commissioning/provenance-manifest.example.json.
