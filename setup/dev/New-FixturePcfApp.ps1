#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the FIXTURE model-driven app that uses the fixture PCF, inside solution ChangeRadarFixtures, in pp-lab.
    Plans by default; -Apply to change.

.DESCRIPTION
    Test asset for pcf_control detection (ADR 0008 addendum, Simon 2026-11-20). Not real data.
    Prerequisite: tests/fixtures/pcf/ChangeRadarFixtures imported (it holds control ChangeRadarFixture.FixtureLabel).
    Creates, as the signed-in user (Az.Accounts), only in the environment named -ExpectedEnvironmentName:
      - table crdr_fixturerecord (primary column crdr_name), description marked FIXTURE
      - its main form, with crdr_name rendered by the fixture control
      - model-driven app crdr_fixturepcfapp with a one-area site map holding that table
    It never deletes. Existing objects are left as they are and reported as 'exists'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EnvironmentUrl,
    [string]$ExpectedEnvironmentName = 'pp-lab',
    [string]$SolutionUniqueName = 'ChangeRadarFixtures',
    [string]$ControlName = 'crdr_ChangeRadarFixture.FixtureLabel',   # Dataverse prefixes the publisher (observed 2026-11-20)
    [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')
$dv = "$EnvironmentUrl/api/data/v9.2"
Import-Module Az.Accounts -ErrorAction Stop
function Invoke-Dv([string]$Path, [string]$Method = 'GET', $Body, [switch]$InSolution) {
    $h = @{ Authorization = "Bearer $(ConvertFrom-SecureString (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -AsSecureString).Token -AsPlainText)"; Accept = 'application/json'; 'OData-Version' = '4.0' }
    if ($InSolution) { $h['MSCRM.SolutionUniqueName'] = $SolutionUniqueName }
    $p = @{ Method = $Method; Uri = "$dv/$Path"; Headers = $h }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 30); $p.ContentType = 'application/json; charset=utf-8' }
    Invoke-RestMethod @p
}
function Get-One([string]$Path) { @((Invoke-Dv $Path).value) | Select-Object -First 1 }
# A new app module is unpublished until PublishXml, and only RetrieveUnpublishedMultiple returns it (observed 2026-11-20).
function Get-App { @((Invoke-Dv "appmodules/Microsoft.Dynamics.CRM.RetrieveUnpublishedMultiple()?`$select=appmoduleid,uniquename").value) + @((Invoke-Dv "appmodules?`$select=appmoduleid,uniquename").value) | Where-Object uniquename -eq 'crdr_fixturepcfapp' | Select-Object -First 1 }
function Label([string]$t) { @{ LocalizedLabels = @(@{ Label = $t; LanguageCode = 1033 }) } }

$org = Invoke-Dv "RetrieveCurrentOrganization(AccessType=@p)?@p=Microsoft.Dynamics.CRM.EndpointAccessType'Default'"
if ($org.Detail.FriendlyName -ne $ExpectedEnvironmentName) { throw "Refusing: environment is '$($org.Detail.FriendlyName)', expected '$ExpectedEnvironmentName'." }
if (-not (Get-One "solutions?`$select=solutionid&`$filter=uniquename eq '$SolutionUniqueName'")) { throw "Import $SolutionUniqueName first (tests/fixtures/pcf)." }
$control = Get-One "customcontrols?`$select=customcontrolid,name&`$filter=name eq '$ControlName'"
if (-not $control) { throw "Control $ControlName not found. Import $SolutionUniqueName first." }

$table = (Invoke-Dv "EntityDefinitions?`$select=LogicalName,MetadataId&`$filter=LogicalName eq 'crdr_fixturerecord'").value | Select-Object -First 1
$app = Get-App
Write-Host "PLAN ($ExpectedEnvironmentName, solution $SolutionUniqueName)"
Write-Host ("  {0,-8} table crdr_fixturerecord" -f ($table ? 'exists' : 'create'))
Write-Host ("  {0,-8} main form uses $ControlName on crdr_name" -f 'ensure')
Write-Host ("  {0,-8} app crdr_fixturepcfapp" -f ($app ? 'exists' : 'create'))
if (-not $Apply) { Write-Host 'Plan only. Nothing was changed. Re-run with -Apply.'; return }

if (-not $table) {
    Invoke-Dv 'EntityDefinitions' POST -InSolution -Body @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.EntityMetadata'; SchemaName = 'crdr_FixtureRecord'
        DisplayName = (Label 'Fixture record'); DisplayCollectionName = (Label 'Fixture records')
        Description = (Label 'FIXTURE: Change Radar test asset, not real. Exists so a form can use the fixture PCF.')
        OwnershipType = 'UserOwned'; HasNotes = $false; HasActivities = $false; IsActivity = $false
        PrimaryNameAttribute = 'crdr_name'
        Attributes = @(@{ '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'; SchemaName = 'crdr_Name'; IsPrimaryName = $true
                MaxLength = 100; FormatName = @{ Value = 'Text' }; DisplayName = (Label 'Name'); RequiredLevel = @{ Value = 'None' } }) } | Out-Null
    Write-Host '  created table'
}
$otc = (Invoke-Dv "EntityDefinitions(LogicalName='crdr_fixturerecord')?`$select=ObjectTypeCode").ObjectTypeCode
$form = Get-One "systemforms?`$select=formid,formxml&`$filter=objecttypecode eq 'crdr_fixturerecord' and type eq 2"
if (-not $form) { throw 'Main form not created yet; publish and re-run.' }
[xml]$fx = $form.formxml
$cell = $fx.SelectSingleNode("//control[@id='crdr_name']")
if (-not $cell) { throw 'crdr_name is not on the main form.' }
# controlDescription.forControl points at the control's uniqueid, not its id (observed in a pp-lab system form, 2026-11-20).
$cid = $cell.GetAttribute('uniqueid')
if (-not $cid) { $cid = "{$([guid]::NewGuid())}"; $cell.SetAttribute('uniqueid', $cid) }
if (-not $fx.SelectSingleNode("//controlDescription[@forControl='$cid']/customControl[@name='$ControlName']")) {
    $descs = $fx.SelectSingleNode('/form/controlDescriptions')
    if (-not $descs) { $descs = $fx.DocumentElement.AppendChild($fx.CreateElement('controlDescriptions')) }
    $d = $fx.CreateElement('controlDescription'); $d.SetAttribute('forControl', $cid)
    # The fixture control for web (0), tablet (2) and phone (1); the parameter element is the manifest property name.
    foreach ($ff in 0, 2, 1) {
        $cc = $fx.CreateElement('customControl'); $cc.SetAttribute('formFactor', "$ff"); $cc.SetAttribute('name', $ControlName)
        $ps = $fx.CreateElement('parameters'); $v = $fx.CreateElement('value'); $v.SetAttribute('type', 'SingleLine.Text'); $v.InnerText = 'crdr_name'
        [void]$ps.AppendChild($v); [void]$cc.AppendChild($ps); [void]$d.AppendChild($cc)
    }
    [void]$descs.AppendChild($d)
    Invoke-Dv "systemforms($($form.formid))" PATCH -InSolution -Body @{ formxml = $fx.OuterXml } | Out-Null
    Write-Host '  form now uses the fixture control'
}
$sm = Get-One "sitemaps?`$select=sitemapid&`$filter=sitemapnameunique eq 'crdr_fixturepcfapp'"
if (-not $sm) {
    $sitemapXml = "<SiteMap IntroducedVersion=`"7.0.0.0`"><Area Id=`"fixture`" ShowGroups=`"true`" Title=`"Fixture`"><Group Id=`"fixture_group`" Title=`"Fixture`"><SubArea Id=`"fixture_records`" Entity=`"crdr_fixturerecord`" Title=`"Fixture records`" /></Group></Area></SiteMap>"
    Invoke-Dv 'sitemaps' POST -InSolution -Body @{ sitemapname = 'crdr_fixturepcfapp'; sitemapnameunique = 'crdr_fixturepcfapp'; sitemapxml = $sitemapXml; isappaware = $true } | Out-Null
    $sm = Get-One "sitemaps?`$select=sitemapid&`$filter=sitemapnameunique eq 'crdr_fixturepcfapp'"
    Write-Host '  created site map'
}
if (-not $app) {
    Invoke-Dv 'appmodules' POST -InSolution -Body @{ name = 'Change Radar fixture PCF app (FIXTURE)'; uniquename = 'crdr_fixturepcfapp'
        description = 'FIXTURE: Change Radar test asset, not real. A model-driven app whose form uses the fixture PCF.'
        webresourceid = '953b9fac-1e5e-e611-80d6-00155ded156f'; clienttype = 4 } | Out-Null
    $app = Get-App
    Write-Host '  created app'
}
# Re-adding existing components is harmless, so this runs every time.
$entityMeta = (Invoke-Dv "EntityDefinitions(LogicalName='crdr_fixturerecord')?`$select=MetadataId").MetadataId
Invoke-Dv 'AddAppComponents' POST -Body @{ AppId = $app.appmoduleid; Components = @(
        @{ '@odata.type' = 'Microsoft.Dynamics.CRM.sitemap'; sitemapid = $sm.sitemapid }
        @{ '@odata.type' = 'Microsoft.Dynamics.CRM.entity'; entityid = $entityMeta }
        @{ '@odata.type' = 'Microsoft.Dynamics.CRM.systemform'; formid = $form.formid }) } | Out-Null
Invoke-Dv 'PublishXml' POST -Body @{ ParameterXml = "<importexportxml><entities><entity>crdr_fixturerecord</entity></entities><appmodules><appmodule>$($app.appmoduleid)</appmodule></appmodules><sitemaps><sitemap>$($sm.sitemapid)</sitemap></sitemaps></importexportxml>" } | Out-Null
$v = Invoke-Dv "ValidateApp(AppModuleId=$($app.appmoduleid))"
Write-Host "Published. ValidateApp: $($v.AppValidationResponse.ValidationSuccess) $(@($v.AppValidationResponse.ValidationIssueList | ForEach-Object Message) -join '; ')"
