VERDICT: PASS

CLAIMS

- The tracked entry was clean at `b3d324ae19c44db731db99eb090333946fc5b57a`; the supervisor-owned `.node-return.md` was the only untracked path before this correction.
- The correction candidate is entry `b3d324ae19c44db731db99eb090333946fc5b57a` plus the two-file patch SHA-256 `ad1d9a57945d3d6e8edc6bff3775ac597faa24136f7a8273f856c7ec62da4858`.
- `scripts/windows/WindowsReceiptAuthority.ps1` SHA-256 is `d1a4c47961313ef44e8fe3f999fb22e7ea6d99d58e5ec3fe8369f17f65d4a0f1`.
- `tests/Test-WindowsReceiptAuthority.ps1` SHA-256 is `b953b3200588b28ffde06d713fb5e014f4a16668257f819d16ca259913d38f7f`.
- Production receipt SHA-256 `0e50130ef4bfd41d7ecc91ad4ae406e8f09a63ef44ecdd8c24c7c83d1d34638e` and authority SHA-256 `5fc24b69a803093e9dfb7f419ab1d362c59f4a32e2becffc8be5e8b54a337e87` were supplied as immutable evidence and were not read, replaced, or modified.
- The checker now obtains `expires_at_utc` from the raw JSON through `System.Text.Json`, requires a JSON string with exact `yyyy-MM-ddTHH:mm:ssZ` spelling, parses invariantly to UTC, disposes the JSON document, and rejects expiry at or before actual UTC now.
- All existing schema, authority/receipt hash, identity, token, ACL, held-handle, executable, uv topology, and provenance checks remain in place.

CARDINALITY

- P1: 0 — none.
- P2: 0 — none.
- P3: 0 — none.
- Changed product/test paths: 2. Added audit paths: 1. No fixture or documentation file was necessary.

CHANGES

- `scripts/windows/WindowsReceiptAuthority.ps1`: added bounded raw-JSON expiry validation and replaced the coerced `DateTime`-to-locale-string parse path.
- `tests/Test-WindowsReceiptAuthority.ps1`: reproduces `ConvertFrom-Json` DateTime coercion and proves canonical-future acceptance plus expired, missing, non-string, fractional, offset, locale-formatted, and invalid-calendar rejection.
- `audit/findings/2026-09-05_issue-1074_authority_timestamp_correction_r6.md`: records this result and its exact evidence.

CHECKS

- `pwsh -NoLogo -NoProfile -File tests/Test-WindowsReceiptAuthority.ps1`: PASS, `Windows receipt-authority source fixture tests passed.`
- The coercion fixture confirms that PowerShell converts the canonical JSON string to `System.DateTime` and that its string cast differs from the canonical source spelling.
- `pwsh -NoLogo -NoProfile -File tests/Test-WindowsAuthorityNative.ps1`: exit 0 with `nativeNOTRUN: Windows authority native token/link/publication checks require Windows.`
- `git diff --check`: PASS.
- Repository validation was bounded at 120 seconds and did not complete; before timeout it reported PASS for profile-chain, launcher fencing/dirty-checkout/forged-marker/pre-line-10, Excel-share input validation, VPS-client convergence, and VPS-access diagnostics. It is not claimed as a complete PASS.

OPEN

- `nativeNOTRUN`: Linux cannot prove Check mode against the existing immutable production pair. The parent must run corrected Check only against that pair in the existing `rdp-natha` InteractiveHighest context; it must not rerun the installer.
- An independent source review remains required at the mechanically finalized clean candidate SHA.

PASS FOR PARENT FINALIZATION AND NATIVE CHECK
