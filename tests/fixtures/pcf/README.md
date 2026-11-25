# Fixture PCF (FIXTURE: test asset, not real)

> **From:** [Empower Your World](https://www.empoweryour.world/?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=tests-fixtures-pcf-readme) · [The story behind Change Radar](https://www.empoweryour.world/blog/change-radar?utm_source=github&utm_medium=docs&utm_campaign=change-radar&utm_content=tests-fixtures-pcf-readme)

Spec §15.1 layer B. It proves that `pcf_control` detection works end to end against a real environment (ADR 0008 addendum, Simon 2026-11-20). It goes into **pp-lab only**, never into a production environment.

| Part | What it is |
|---|---|
| `FixtureLabel/` | A minimal field code component, `ChangeRadarFixture.FixtureLabel`. It shows `[fixture] <value>`. Dataverse stores it as `crdr_ChangeRadarFixture.FixtureLabel`. |
| `ChangeRadarFixtures/` | The unmanaged solution that ships it (publisher ChangeRadar, prefix `crdr`). |
| `setup/dev/New-FixturePcfApp.ps1` | Creates table `crdr_fixturerecord`, sets its main form to use the control, and creates model-driven app `crdr_fixturepcfapp`, all inside ChangeRadarFixtures. Plans by default. |

Build and import (Node via fnm, then the .NET SDK):

```powershell
cd tests/fixtures/pcf/FixtureLabel; npm ci; npm run build
cd ../ChangeRadarFixtures; dotnet build -c Debug
pac solution check --path bin/Debug/ChangeRadarFixtures.zip --environment <pp-lab url>
pac solution import --path bin/Debug/ChangeRadarFixtures.zip --environment <pp-lab url> --publish-changes
pwsh -File setup/dev/New-FixturePcfApp.ps1 -EnvironmentUrl <pp-lab url> -Apply
```

Check it with `queries/inventory.ps1` and then `queries/dataverse-detail.ps1`. The fixture app should be the only app with a maker-built control.
