# rims-frontend

Flutter frontend code lives in [`rims_frontend`](rims_frontend).

For local APP verification, backend API configuration, and test account source,
see [`rims_frontend/README.md`](rims_frontend/README.md).

## Managed Local Workflow

Run local services and acceptance checks from the repository root with Windows
PowerShell 5.1 or later:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command doctor -Target web
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command up -Target web -IncludeDependencies
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command status
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command logs
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command reset
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command smoke -Target web -IncludeDependencies
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command smoke -Target android -IncludeDependencies -AndroidDevice $env:RIMS_ANDROID_DEVICE
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_local.ps1 -Command down
```

The controller starts only resources whose identity it can persist and later
verify by PID, process start time, and platform-specific identity. `down` stops
only those owned resources. Existing PostgreSQL containers, Android emulators,
and unrelated listeners remain user-managed. A conflicting unmanaged port or
incompatible `.runtime/rims-local/state.json` causes a nonzero exit instead of
an implicit takeover.

Runtime state, sanitized logs, smoke reports, screenshots, and baseline samples
are written under `.runtime/rims-local/`. Web and Android acceptance use a
shared lock, so they cannot reset fixtures or stop services concurrently. Both
smokes restore the deterministic fixture baseline and return the first required
step failure.

### Prerequisites And Overrides

- WSL must provide `bash` and Go at `~/local/go/bin/go`.
- Docker and Docker Compose must be available for the local PostgreSQL service.
- Flutter and Git must be on `PATH`.
- Android smoke requires an installed AVD and Android SDK platform tools.
- The default backend runtime root is `E:\My Work\RIMS`; override it with
  `RIMS_BACKEND_WORKSPACE_ROOT`.
- Override backend source with `RIMS_BACKEND_DIR`, Android AVD with
  `RIMS_ANDROID_DEVICE`, and individual ports with command parameters.

M9 local identities are `admin/admin123` and `m9_operator/admin123`. The
operator is bound to `WH001` and `M9-WH-02`; these credentials and fixtures are
for local `dev`, `development`, or `test` environments only. Never run fixture
seed or reset commands against staging or production data.

Collect the local regression baseline after current Web and Android smoke
reports exist:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_m9_baseline.ps1 -OutputPath .runtime\rims-local\reports\m9-baseline.json
```

## M10 Android Field Acceptance

The M10 wrapper starts the backend and the exact named AVD, resets local-only
fixtures, grants/revokes camera permission for probes, runs scanner, multi-line
document, stock-effect, and attachment recovery checks, then restores the
fixture baseline and removes only owned resources:

```powershell
$env:RIMS_ANDROID_DEVICE = 'Medium_Phone_API_36.1'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rims_m10_smoke.ps1 -AndroidDevice $env:RIMS_ANDROID_DEVICE -BackendDir $env:RIMS_BACKEND_DIR -Output Json
```

No cloud account or object store is required. Managed backend files live under
`.runtime/rims-local/providers/files`; reports and transient provider evidence
live under `.runtime/reports/` and `.runtime/m10-smoke-artifacts/`. The local
fixtures include `admin/admin123`, `m9_operator/admin123`, and barcodes
`M10-ACTIVE-001`, `M10-DISABLED-001`, and `M10-WH001-ONLY-001`.

The main manifest requests camera only and keeps camera hardware optional.
Android system gallery/file pickers use scoped access and require no legacy
storage permission. Run `reset` only against `dev`, `development`, or `test`;
the controller rejects incompatible runtime ownership instead of taking it over.

## License

SPDX-License-Identifier: AGPL-3.0-only

Copyright (C) 2026 ShangBin Wang

This project is licensed under the GNU Affero General Public License v3.0 only. See [LICENSE](LICENSE) for details.
