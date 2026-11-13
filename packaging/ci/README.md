This directory is the public, synthetic-data-only MSI test harness. Copy
verify-msi.yml to .github/workflows/verify-msi.yml in the release repository.
The workflow never publishes a release or writes an update manifest.

The request .qa/msi-candidate-request.json has this shape:

```json
{
  "schema": 1,
  "ready": false,
  "release_id": 1,
  "asset_id": 1,
  "asset_name": "QContract-Setup-2.3.0.msi",
  "version": "2.3.0",
  "size": 1,
  "sha256": "REPLACE_WITH_EXACT_CANDIDATE_SHA256",
  "expected_manifest": {
    "path": "runtime/client-integrity.json",
    "sha256": "REPLACE_WITH_EXACT_EMBEDDED_MANIFEST_SHA256"
  }
}
```

ready=false deliberately skips installation and produces a failed readiness
result. Set ready=true only after review, with the actual draft release and
asset IDs, bytes and hashes. Release and asset metadata, the complete MSI hash,
and an active Defender custom scan are checked before opening its MSI database
or running Windows Installer. Every installed payload file is checked against
the separately pinned integrity manifest before executing bundled code.

Execution is allowed only inside a GitHub-hosted Windows job in the fixed
release repository. Never run smoke-msi.ps1 on an owner's or tester's computer.
The token has contents:read only, is sent only to the initial GitHub API host,
and is cleared before installation; redirected downloads receive no token.
Creating the workflow file itself may require GitHub Workflows write permission;
this does not justify expanding the activation app's existing permissions.

The job uses the standard windows-2025 hosted image: a fresh Windows Server 2025
VM with preinstalled development tools. The initial read-only readiness run
43508342110 found its Defender service/antivirus in Normal mode, but real-time
protection disabled; that run failed before any candidate download or execution.
The revised first step requires that existing Normal-mode service and enables
real-time protection, when needed, with only the supported command
`Set-MpPreference -DisableRealtimeMonitoring $false`. Strong hosted Windows,
repository and main-branch guards precede that action. Verification has a
60-second bound and must show service, antivirus and real-time protection active
in Normal mode before checkout or download. If policy refuses, the job fails;
there are no tamper/registry workarounds, exclusions, restores, or other preference
changes. No owner's or tester's device is modified by this bootstrap.

This remains different from a clean consumer Windows 10/11 certification.
A bundled-process DLL probe checks that VC runtime DLLs resolve inside the package,
rather than relying on preinstalled development tools. The inference process gets
its own outbound firewall block in this disposable VM. Firewall profiles must
already be enabled; its unique process rule is removed in finally.
Only synthetic state is used; logs and result JSON expire
after three days. No real IDs, license, private keys, user data, profile, MSI, or
download URLs are uploaded as workflow artifacts.

Checks cover fresh per-user install, desktop/Start shortcut and AUMID, marker,
.NET/standalone host diagnosis, fixed WebView vendor signature and AppContainer
RX permissions, prerequisite/payload integrity, VC dependency closure, inference
while its process has no outbound network, same-version reinstall, uninstall,
and synthetic company/employee/contract/photo/DPAPI-cache preservation. Migration
from the previous Inno 2.2 installer, Word/PDF rendering and accuracy on real IDs
remain separate tests. A green result does not certify HP Wolf acceptance or
constitute a malware-free guarantee. The installer is still a draft candidate.

Primary references:

- https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job
- https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28#get-a-release-asset
- https://learn.microsoft.com/en-us/defender-endpoint/command-line-arguments-microsoft-defender-antivirus
