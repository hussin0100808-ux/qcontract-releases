param([Parameter(Mandatory=$true)][string]$RequestPath,[string]$StagedCandidatePath)

# This is an execution harness for an ephemeral GitHub VM, never a local installer.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$repository = 'hussin0100808-ux/qcontract-releases'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne $repository -or
    $env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_JOB -ne 'smoke' -or -not $env:RUNNER_TEMP) {
  throw 'Refusing execution outside the approved GitHub-hosted Windows main-branch job.'
}

Add-Type -AssemblyName System.Net.Http
$resultRoot = Join-Path $env:RUNNER_TEMP 'qcontract-msi-results'
$workRoot = Join-Path $env:RUNNER_TEMP ('qcontract-msi-' + [guid]::NewGuid().ToString('N'))
$installRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\QContract'
$dataRoot = Join-Path $env:LOCALAPPDATA 'QContract\Data'
$diagRoot = Join-Path $workRoot 'diagnostic-data'
New-Item -ItemType Directory -Path $resultRoot,$workRoot -Force | Out-Null
$result = [ordered]@{schema=1;status='failed';release_ready=$false;repository=$repository;
  run_id=$env:GITHUB_RUN_ID;run_attempt=$env:GITHUB_RUN_ATTEMPT;commit=$env:GITHUB_SHA;
  runner_image='windows-2025';image_version=$env:ImageVersion;
  migration_from_inno_220_tested=$false;consumer_windows_10_11_tested=$false;
  hp_wolf_acceptance_tested=$false;gui_interaction_tested=$false}
$firewallName = $null
$installedProduct = $null
$candidatePath = Join-Path $workRoot 'candidate.msi'
$token = $env:QA_GITHUB_TOKEN
$request = $null

function Assert-Hash([string]$Path,[string]$Expected,[long]$Size=-1) {
  $item = Get-Item -LiteralPath $Path
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Nonregular payload file.' }
  if ($Size -ge 0 -and $item.Length -ne $Size) { throw 'Payload byte count mismatch.' }
  if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Expected) { throw 'Payload SHA256 mismatch.' }
}

function Resolve-PayloadPath([string]$Root,[string]$Relative) {
  if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -notmatch '^[A-Za-z0-9_ .()@+\-/]+$' -or
      $Relative.Contains('\') -or $Relative.StartsWith('/') -or $Relative.Split('/') -contains '..' -or
      $Relative.Split('/') -contains '.' -or $Relative.Contains('//')) { throw 'Invalid manifest relative path.' }
  $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  $resolved = [IO.Path]::GetFullPath((Join-Path $Root $Relative.Replace('/','\')))
  if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path escaped payload root.' }
  $current = $resolved
  while ($current.Length -ge $prefix.Length) {
    if (Test-Path -LiteralPath $current) {
      if ((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Payload path contains a reparse point.' }
    }
    $current = Split-Path -Parent $current
  }
  return $resolved
}

function New-ApiRequest([string]$Url,[string]$Accept,[bool]$Authenticate) {
  $uri = [uri]$Url
  if ($uri.Scheme -cne 'https' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or
      $uri.DnsSafeHost -notin @('api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com','github-releases.githubusercontent.com')) {
    throw 'Unapproved GitHub download host.'
  }
  $message = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get,$uri)
  $message.Headers.UserAgent.ParseAdd('QContract-candidate-QA/1')
  $message.Headers.Accept.ParseAdd($Accept)
  if ($Authenticate) {
    if ($uri.DnsSafeHost -cne 'api.github.com' -or -not $token) { throw 'API token missing or authentication target invalid.' }
    $message.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer',$token)
    $message.Headers.Add('X-GitHub-Api-Version','2022-11-28')
  }
  return $message
}

function Get-ApiJson([string]$Url) {
  $message = New-ApiRequest $Url 'application/vnd.github+json' $true
  try {
    $response = $http.SendAsync($message).GetAwaiter().GetResult()
    try {
      if ([int]$response.StatusCode -ne 200) { throw 'GitHub metadata request failed.' }
      if ($response.Content.Headers.ContentLength -gt 2097152) { throw 'Oversized GitHub metadata.' }
      $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      if ($body.Length -gt 2097152) { throw 'Oversized GitHub metadata.' }
      return $body | ConvertFrom-Json
    } finally { $response.Dispose() }
  } catch { throw 'Could not read approved GitHub metadata.' }
  finally { $message.Dispose() }
}

function Save-Candidate([string]$Url,[long]$ExpectedSize) {
  for ($redirect=0; $redirect -le 5; $redirect++) {
    # Authentication is never forwarded, even if a redirect returns to the API.
    $message = New-ApiRequest $Url 'application/octet-stream' ($redirect -eq 0)
    try {
      $response = $http.SendAsync($message,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      try {
        $status = [int]$response.StatusCode
        if ($status -in @(301,302,303,307,308)) {
          if ($redirect -eq 5 -or -not $response.Headers.Location) { throw 'Download redirect limit.' }
          $Url = ([uri]::new([uri]$Url,$response.Headers.Location)).AbsoluteUri
          continue
        }
        if ($status -ne 200) { throw 'Candidate download failed.' }
        if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -ne $ExpectedSize) { throw 'Download content length differs.' }
        $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [IO.File]::Open($candidatePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
          $buffer = New-Object byte[] 1048576
          [long]$total = 0
          while (($read = $source.Read($buffer,0,$buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $ExpectedSize) { throw 'Candidate exceeded expected byte count.' }
            $output.Write($buffer,0,$read)
          }
          if ($total -ne $ExpectedSize) { throw 'Incomplete candidate download.' }
        } finally { $output.Dispose(); $source.Dispose() }
        return
      } finally { $response.Dispose() }
    } catch { throw 'Candidate download refused or incomplete; URL details suppressed.' }
    finally { $message.Dispose() }
  }
  throw 'Candidate download did not complete.'
}

function Assert-DefenderActive {
  $state = Get-MpComputerStatus
  if (-not $state.AMServiceEnabled -or -not $state.AntivirusEnabled -or -not $state.RealTimeProtectionEnabled -or
      $state.AMRunningMode -ne 'Normal') { throw 'Defender active real-time protection is required; settings will not be changed.' }
  $result.defender = [ordered]@{active=$true;real_time=$true;engine=$state.AMEngineVersion;
    signature=$state.AntivirusSignatureVersion;signature_updated_utc=$state.AntivirusSignatureLastUpdated.ToUniversalTime().ToString('o')}
}

function Invoke-DefenderScan([string]$Target,[string]$Name) {
  Assert-DefenderActive
  $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
  $choices = @()
  if (Test-Path -LiteralPath $platform) {
    $choices = @(Get-ChildItem -LiteralPath $platform -Directory | Sort-Object Name -Descending |
      ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' } | Where-Object { Test-Path -LiteralPath $_ })
  }
  $choices += Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
  $scanner = $choices | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $scanner) { throw 'Defender scanner is unavailable.' }
  Assert-MicrosoftSignature $scanner
  $outPath = Join-Path $resultRoot ($Name + '-defender.log')
  $errPath = Join-Path $workRoot ($Name + '-defender.stderr')
  $process = Start-Process -FilePath $scanner -ArgumentList @('-Scan','-ScanType','3','-File',('"'+$Target+'"'),'-DisableRemediation') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
  $scanText = (Get-Content -LiteralPath $outPath -Raw) + (Get-Content -LiteralPath $errPath -Raw)
  # Exit zero alone may also mean a threat was remediated. Require explicit clean text.
  if ($process.ExitCode -ne 0 -or $scanText -notmatch '(?i)(found no threats|no threats (?:were )?(?:found|detected))') { throw 'Defender did not produce an explicit clean scan result.' }
  $result[$Name + '_defender_clean'] = $true
}

function Assert-MicrosoftSignature([string]$Path) {
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|, )O=Microsoft Corporation(?:,|$)') { throw 'Microsoft runtime signature validation failed.' }
}

function Read-MsiRows([object]$Database,[string]$Sql) {
  $view = Invoke-ComMethod $Database 'OpenView' @($Sql)
  $rows = New-Object System.Collections.Generic.List[object]
  try {
    [void](Invoke-ComMethod $view 'Execute')
    while ($null -ne ($record = Invoke-ComMethod $view 'Fetch')) {
      try {
        $values = @()
        $fieldCount = Get-ComProperty $record 'FieldCount'
        for ($i=1; $i -le $fieldCount; $i++) { $values += [string](Get-ComProperty $record 'StringData' @($i)) }
        $rows.Add($values)
      } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
    }
  } finally { [void](Invoke-ComMethod $view 'Close'); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
  foreach ($row in $rows) { Write-Output -NoEnumerate $row }
}

function Invoke-ComMethod($Target,[string]$Name,[object[]]$Arguments=@()) {
  $value = $Target.GetType().InvokeMember($Name,[Reflection.BindingFlags]::InvokeMethod,$null,$Target,$Arguments)
  return ,$value
}

function Get-ComProperty($Target,[string]$Name,[object[]]$Arguments=@()) {
  $value = $Target.GetType().InvokeMember($Name,[Reflection.BindingFlags]::GetProperty,$null,$Target,$Arguments)
  return ,$value
}

function Get-ExpectedProductCode([string]$Version) {
  $namespaceHex = '25b856035ee54a929b32b61e9e490b17'
  $namespaceBytes = New-Object byte[] 16
  for ($i=0; $i -lt 16; $i++) { $namespaceBytes[$i] = [Convert]::ToByte($namespaceHex.Substring($i*2,2),16) }
  [byte[]]$inputBytes = $namespaceBytes + [Text.Encoding]::UTF8.GetBytes('qcontract-x64-user/'+$Version)
  $sha1 = [Security.Cryptography.SHA1]::Create()
  try { $guidHash = $sha1.ComputeHash($inputBytes) } finally { $sha1.Dispose() }
  $guidHash[6] = ($guidHash[6] -band 15) -bor 80
  $guidHash[8] = ($guidHash[8] -band 63) -bor 128
  $hex = (($guidHash[0..15] | ForEach-Object { $_.ToString('x2') }) -join '')
  return [Guid]::Parse($hex).ToString('B').ToUpperInvariant()
}

function Assert-MsiTables([string]$Path) {
  $installer = New-Object -ComObject WindowsInstaller.Installer
  $database = Invoke-ComMethod $installer 'OpenDatabase' @($Path,0)
  $tables = @(Read-MsiRows $database 'SELECT `Name` FROM `_Tables`' | ForEach-Object { $_[0] })
  $approvedTables = @('_Tables','_Columns','_Validation','_Streams','_Storages','Property','Directory','Feature',
    'Component','FeatureComponents','File','Registry','CreateFolder','Shortcut','MsiShortcutProperty','IniFile','RemoveFile',
    'RegLocator','AppSearch','LaunchCondition','Upgrade','MsiLockPermissionsEx','InstallExecuteSequence','InstallUISequence',
    'Media','Icon','MsiFileHash','QContractPayloadHash','Signature')
  foreach ($table in $tables) { if ($table -notin $approvedTables) { throw 'Unapproved MSI table.' } }
  if ($tables -notcontains 'Signature' -or @(Read-MsiRows $database 'SELECT `Signature`,`FileName`,`MinVersion`,`MaxVersion`,`MinSize`,`MaxSize`,`MinDate`,`MaxDate`,`Languages` FROM `Signature`').Count -ne 0) {
    throw 'The standard empty Signature table is required for raw registry prerequisite searches.'
  }
  foreach ($table in @('CustomAction','ServiceInstall','ServiceControl','SelfReg','TypeLib','MsiEmbeddedUI','MsiEmbeddedChainer','ODBCDriver','ODBCTranslator','Extension','Verb','ProgId','Class','AppId','Environment','MoveFiles','DuplicateFile')) {
    if ($tables -contains $table) {
      if (@(Read-MsiRows $database ('SELECT * FROM `' + $table + '`')).Count -ne 0) { throw 'MSI contains an executable/custom/service registration table.' }
    }
  }
  $properties = @{}
  foreach ($row in (Read-MsiRows $database 'SELECT `Property`,`Value` FROM `Property`')) { $properties[$row[0]] = $row[1] }
  $expectedProperties = @{
    ProductCode=(Get-ExpectedProductCode $request.version);UpgradeCode='{25B85603-5EE5-4A92-9B32-B61E9E490B17}';
    ProductName='Q Contract';Manufacturer='Q Contract';ProductVersion=$request.version;ProductLanguage='1025';
    MSIINSTALLPERUSER='1';INSTALLLEVEL='1';ARPNOMODIFY='1';REBOOT='ReallySuppress';REINSTALLMODE='amus';
    ARPPRODUCTICON='QContractIcon';ARPHELPLINK='https://github.com/hussin0100808-ux/qcontract-releases/issues';
    ARPURLUPDATEINFO='https://github.com/hussin0100808-ux/qcontract-releases/releases';
    SecureCustomProperties='QC_OLDPRODUCTS;QC_NEWERPRODUCTS;QC_OSBUILD;QC_NETFX4_RELEASE;QC_OLDINNO;INSTALLDIR'
  }
  if ($properties.Count -ne $expectedProperties.Count) { throw 'Unexpected MSI property count.' }
  foreach ($name in $properties.Keys) {
    if (-not $expectedProperties.ContainsKey($name) -or $properties[$name] -cne $expectedProperties[$name]) { throw 'Unapproved MSI property or value.' }
  }
  if ($properties['ProductVersion'] -cne $request.version -or $properties['ProductName'] -cne 'Q Contract' -or
      $properties['UpgradeCode'] -cne '{25B85603-5EE5-4A92-9B32-B61E9E490B17}' -or
      $properties['ProductCode'] -notmatch '^\{[A-Fa-f0-9-]{36}\}$' -or
      ($properties.ContainsKey('ALLUSERS') -and $properties['ALLUSERS'] -ne '') -or
      $properties['MSIINSTALLPERUSER'] -ne '1') { throw 'MSI identity or per-user scope is unexpected.' }
  $summaryInformation = Get-ComProperty $database 'SummaryInformation' @(0)
  try {
    if ((Get-ComProperty $summaryInformation 'Property' @(15)) -ne 10) { throw 'MSI elevated-install summary flag is unexpected.' }
  } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summaryInformation) }
  $directories = @{}
  foreach ($row in (Read-MsiRows $database 'SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`')) { $directories[$row[0]] = $row }
  $fixedDirectories = @{
    TARGETDIR=@('','SourceDir');LocalAppDataFolder=@('TARGETDIR','LocalAppData');ProgramsDir=@('LocalAppDataFolder','Programs');
    INSTALLDIR=@('ProgramsDir','QContract');DesktopFolder=@('TARGETDIR','Desktop');ProgramMenuFolder=@('TARGETDIR','Programs');
    QContractMenu=@('ProgramMenuFolder','QCONT~1|Q Contract')
  }
  foreach ($id in $fixedDirectories.Keys) {
    if (-not $directories.ContainsKey($id) -or $directories[$id][1] -cne $fixedDirectories[$id][0] -or
        $directories[$id][2] -cne $fixedDirectories[$id][1]) { throw 'MSI known-folder hierarchy is unexpected.' }
  }
  $payloadDirectories = @{'INSTALLDIR'=''}
  function Resolve-MsiDirectory([string]$Id,[string[]]$Ancestors=@()) {
    if ($payloadDirectories.ContainsKey($Id)) { return [string]$payloadDirectories[$Id] }
    if ($Id -cnotmatch '^D[0-9]{6}$' -or -not $directories.ContainsKey($Id) -or $Ancestors -contains $Id -or $Ancestors.Count -gt 128) { throw 'MSI directory escapes the owned payload tree.' }
    $row = $directories[$Id]
    $leaf = ($row[2] -split '\|')[-1]
    if ($leaf -notmatch '^[A-Za-z0-9_ .()@+\-]+$' -or $leaf -in @('.','..') -or $leaf.EndsWith('.') -or $leaf.EndsWith(' ')) { throw 'Unsafe MSI directory name.' }
    $parent = Resolve-MsiDirectory $row[1] ($Ancestors + $Id)
    $relative = ($parent + '/' + $leaf).TrimStart('/')
    $null = Resolve-PayloadPath $installRoot $relative
    $payloadDirectories[$Id] = $relative
    return $relative
  }
  foreach ($id in $directories.Keys) {
    if ($properties.ContainsKey($id)) { throw 'MSI property unexpectedly overrides a directory.' }
    if (-not $fixedDirectories.ContainsKey($id)) { $null = Resolve-MsiDirectory $id }
  }
  $components = @{}
  foreach ($row in (Read-MsiRows $database 'SELECT `Component`,`Directory_`,`Attributes`,`Condition` FROM `Component`')) {
    if (-not $payloadDirectories.ContainsKey($row[1]) -or $row[2] -ne '260' -or $row[3] -ne '') { throw 'MSI component has an unsafe location or attributes.' }
    $components[$row[0]] = $row[1]
  }
  $filePaths = @{}
  $fileSizes = @{}
  foreach ($row in (Read-MsiRows $database 'SELECT `File`,`Component_`,`FileName`,`FileSize`,`Attributes` FROM `File`')) {
    if (-not $components.ContainsKey($row[1]) -or $row[4] -ne '512' -or $row[3] -notmatch '^[0-9]+$') { throw 'Invalid MSI file component or attributes.' }
    $leaf = ($row[2] -split '\|')[-1]
    if ($leaf -notmatch '^[A-Za-z0-9_ .()@+\-]+$' -or $leaf -in @('.','..') -or $leaf.EndsWith('.') -or $leaf.EndsWith(' ')) { throw 'Unsafe MSI file name.' }
    $relative = ($payloadDirectories[$components[$row[1]]] + '/' + $leaf).TrimStart('/')
    $null = Resolve-PayloadPath $installRoot $relative
    $filePaths[$row[0]] = $relative
    $fileSizes[$row[0]] = [long]$row[3]
  }
  foreach ($row in (Read-MsiRows $database 'SELECT `Directory_`,`Component_` FROM `CreateFolder`')) {
    if (($row[0] -ne 'QContractMenu' -and -not $payloadDirectories.ContainsKey($row[0])) -or
        -not $components.ContainsKey($row[1])) { throw 'MSI folder creation escaped owned locations.' }
  }
  $removals = @(Read-MsiRows $database 'SELECT `FileKey`,`Component_`,`FileName`,`DirProperty`,`InstallMode` FROM `RemoveFile`')
  if ($removals.Count -ne 2) { throw 'Unexpected MSI uninstall deletion count.' }
  foreach ($row in $removals) {
    if ($row[4] -ne '2' -or
        ($row[0] -eq 'RemoveInstalledMarker' -and ($row[1] -ne 'CMarker' -or $row[2] -cne 'installed.marker' -or $row[3] -ne 'INSTALLDIR')) -or
        ($row[0] -eq 'RemoveStartMenuFolder' -and ($row[1] -ne 'CShortcuts' -or $row[2] -ne '' -or $row[3] -ne 'QContractMenu')) -or
        $row[0] -notin @('RemoveInstalledMarker','RemoveStartMenuFolder')) { throw 'MSI uninstall rule may delete unowned files.' }
  }
  $ini = @(Read-MsiRows $database 'SELECT `FileName`,`DirProperty`,`Section`,`Key`,`Value`,`Action`,`Component_` FROM `IniFile`')
  if ($ini.Count -ne 1 -or ($ini[0][0] -split '\|')[-1] -cne 'installed.marker' -or
      ($ini[0][1..6] -join '|') -cne 'INSTALLDIR|Installation|Type|per-user|0|CMarker') { throw 'Unexpected MSI INI write.' }
  $directorySddl = 'D:AI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;<[%USERDOMAIN]\[%USERNAME]>)(A;OICI;0x1200a9;;;S-1-15-2-1)(A;OICI;0x1200a9;;;S-1-15-2-2)'
  $fileSddl = 'D:AI(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;<[%USERDOMAIN]\[%USERNAME]>)(A;;0x1200a9;;;S-1-15-2-1)(A;;0x1200a9;;;S-1-15-2-2)'
  foreach ($row in (Read-MsiRows $database 'SELECT `LockObject`,`Table`,`SDDLText`,`Condition` FROM `MsiLockPermissionsEx`')) {
    if ($row[3] -ne '') { throw 'Unexpected conditional MSI permission change.' }
    if ($row[1] -eq 'CreateFolder') {
      if (-not $payloadDirectories.ContainsKey($row[0]) -or $row[2] -cne $directorySddl -or
          $payloadDirectories[$row[0]] -notmatch '^runtime/webview2(?:/|$)') { throw 'MSI directory permission change escaped the bundled WebView runtime.' }
    } elseif ($row[1] -eq 'File') {
      if (-not $filePaths.ContainsKey($row[0]) -or $row[2] -cne $fileSddl -or
          $filePaths[$row[0]] -notmatch '^runtime/webview2/') { throw 'MSI file permission change escaped the bundled WebView runtime.' }
    } else { throw 'Unapproved MSI permission target table.' }
  }
  foreach ($row in (Read-MsiRows $database 'SELECT `DiskId`,`Cabinet`,`Source` FROM `Media`')) {
    if ($row[1] -cnotmatch '^#payload[0-9]{3}\.cab$' -or $row[2] -ne '') { throw 'MSI payload is not entirely embedded.' }
  }
  $payloadHashes = @(Read-MsiRows $database 'SELECT `File_`,`RelativePath`,`SHA256`,`Size` FROM `QContractPayloadHash`')
  if ($payloadHashes.Count -ne $filePaths.Count) { throw 'MSI payload hash table is incomplete.' }
  $manifestRows = @()
  foreach ($row in $payloadHashes) {
    if (-not $filePaths.ContainsKey($row[0]) -or $filePaths[$row[0]] -cne $row[1] -or $row[2] -cnotmatch '^[a-f0-9]{64}$' -or
        [long]$row[3] -ne $fileSizes[$row[0]]) { throw 'MSI payload metadata and file paths disagree.' }
    if ($row[1] -ceq $request.expected_manifest.path) { $manifestRows += ,$row }
  }
  if ($manifestRows.Count -ne 1 -or $manifestRows[0][2] -cne $request.expected_manifest.sha256) { throw 'MSI embedded integrity-manifest hash is not the approved hash.' }
  foreach ($row in (Read-MsiRows $database 'SELECT `Property`,`Signature_` FROM `AppSearch`')) {
    if (($row -join '|') -notin @('QC_OSBUILD|RegOSBuild','QC_NETFX4_RELEASE|RegNetFx','QC_OLDINNO|RegOldInno')) { throw 'Unapproved MSI AppSearch assignment.' }
  }
  $locators = @(Read-MsiRows $database 'SELECT `Signature_`,`Root`,`Key`,`Name`,`Type` FROM `RegLocator`')
  $expectedLocators = @{
    RegOSBuild='RegOSBuild|2|SOFTWARE\Microsoft\Windows NT\CurrentVersion|CurrentBuildNumber|18';
    RegNetFx='RegNetFx|2|SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full|Release|18';
    RegOldInno='RegOldInno|1|Software\Microsoft\Windows\CurrentVersion\Uninstall\{72E8C753-287A-45A4-AE36-A45E1E7411E6}_is1|UninstallString|2'
  }
  if ($locators.Count -ne $expectedLocators.Count) { throw 'Unexpected MSI registry read count.' }
  foreach ($row in $locators) {
    if (-not $expectedLocators.ContainsKey($row[0]) -or ($row -join '|') -cne $expectedLocators[$row[0]]) { throw 'Unapproved MSI registry read.' }
  }
  foreach ($row in (Read-MsiRows $database 'SELECT `UpgradeCode`,`ActionProperty` FROM `Upgrade`')) {
    if ($row[0] -cne '{25B85603-5EE5-4A92-9B32-B61E9E490B17}' -or $row[1] -notin @('QC_OLDPRODUCTS','QC_NEWERPRODUCTS')) { throw 'MSI upgrade targets an unowned product family.' }
  }
  if ($tables -contains 'Registry') {
    foreach ($row in (Read-MsiRows $database 'SELECT `Root`,`Key`,`Name`,`Value` FROM `Registry`')) {
      if ($row[0] -ne '1' -or $row[1] -notmatch '^Software\\QContract\\Installer(?:\\|$)' -or
          $row[1] -match '(?i)(?:^|\\)(Run|RunOnce|Startup|Services|Winlogon)(?:\\|$)') { throw 'Unexpected registry or autostart write in MSI.' }
    }
  }
  $shortcuts = @(Read-MsiRows $database 'SELECT `Directory_`,`Name`,`Target`,`Arguments` FROM `Shortcut`')
  if ($shortcuts.Count -ne 2 -or @($shortcuts | Where-Object { $_[0] -eq 'DesktopFolder' }).Count -ne 1 -or
      @($shortcuts | Where-Object { $_[0] -eq 'QContractMenu' }).Count -ne 1) { throw 'Unexpected MSI shortcut table.' }
  $target = $shortcuts[0][2]
  if ($target -notmatch '^\[#([A-Za-z0-9_.]+)\]$') { throw 'MSI shortcut is not a direct installed-file target.' }
  $targetFile = $Matches[1]
  $files = @(Read-MsiRows $database 'SELECT `File`,`FileName` FROM `File`' | Where-Object { $_[0] -eq $targetFile })
  if ($files.Count -ne 1 -or $filePaths[$targetFile] -cne 'app/desktop_host/QContract.exe') { throw 'MSI shortcut targets an unexpected executable.' }
  foreach ($row in $shortcuts) {
    if ($row[2] -cne $target -or $row[3] -ne '' -or ($row[1] -split '\|')[-1] -cne 'Q Contract') { throw 'MSI shortcut includes unexpected target or arguments.' }
  }
  $allowedActions = @('AppSearch','FindRelatedProducts','LaunchConditions','ValidateProductID','CostInitialize','FileCost',
    'CostFinalize','MigrateFeatureStates','InstallValidate','RemoveExistingProducts','InstallInitialize','ProcessComponents',
    'UnpublishFeatures','RemoveRegistryValues','RemoveIniValues','RemoveShortcuts','RemoveFiles','RemoveFolders','CreateFolders',
    'InstallFiles','CreateShortcuts','WriteRegistryValues','WriteIniValues','RegisterUser','RegisterProduct','PublishFeatures',
    'PublishProduct','InstallFinalize','ExecuteAction')
  foreach ($table in @('InstallExecuteSequence','InstallUISequence')) {
    foreach ($row in (Read-MsiRows $database ('SELECT `Action` FROM `'+$table+'`'))) {
      if ($row[0] -notin $allowedActions) { throw 'Unexpected MSI execution sequence action.' }
    }
  }
  $result.msi_static_preflight = $true
  [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
  [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
  return $properties['ProductCode']
}

function Invoke-Msi([string]$Operation,[string]$LogName) {
  $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
  Assert-MicrosoftSignature $msiexec
  $log = Join-Path $resultRoot ($LogName + '.log')
  if ($Operation -eq 'uninstall') {
    $arguments = @('/x',$installedProduct,'/qn','/norestart','/l*v',('"'+$log+'"'))
  } else {
    $arguments = @('/i',('"'+$candidatePath+'"'),'/qn','/norestart','ALLUSERS=""','MSIINSTALLPERUSER=1','/l*v',('"'+$log+'"'))
    if ($Operation -eq 'reinstall') { $arguments += @('REINSTALL=ALL','REINSTALLMODE=vomus') }
  }
  $process = Start-Process -FilePath $msiexec -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
  $result[$LogName + '_exit_code'] = $process.ExitCode
  if ($process.ExitCode -ne 0) {
    Write-Output 'QCONTRACT_INSTALL_FAILURE_LOG_BEGIN'
    Select-String -LiteralPath $log -Pattern 'Error [0-9]{3,4}|Return value 3|error status: [0-9]+' -Context 4,3 |
      Select-Object -First 8 | ForEach-Object { Write-Output $_.ToString() }
    Write-Output 'QCONTRACT_INSTALL_FAILURE_LOG_END'
    throw ('Windows Installer failed or requested a reboot during ' + $Operation + '.')
  }
}

function Get-MsiProductRegistrations([string]$ProductCode) {
  if ($ProductCode -notmatch '^\{[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\}$') { throw 'Invalid product code for read-only MSI inventory.' }
  $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
  if (-not [IO.Path]::IsPathRooted($systemDirectory) -or [IO.Path]::GetFileName($systemDirectory) -ine 'System32') { throw 'Cannot resolve the native Windows system directory.' }
  Assert-MicrosoftSignature (Join-Path $systemDirectory 'msi.dll')
  if (-not ('QContractQa.MsiInventory' -as [type])) {
    # Metadata enumeration only. System32-only DLL resolution; no installer,
    # product-open, action or repair API is exposed by this helper.
    $inventorySource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace QContractQa {
  public sealed class MsiRegistration {
    public string ProductCode;
    public uint Context;
    public string UserSid;
  }
  public static class MsiInventory {
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [DllImport("msi.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    private static extern uint MsiEnumProductsExW(string productCode, string userSid,
      uint context, uint index, StringBuilder installedProductCode,
      out uint installedContext, StringBuilder installedUserSid, ref uint userSidLength);
    public static MsiRegistration[] Enumerate(string productCode) {
      var registrations = new List<MsiRegistration>();
      for (uint index=0; index<8; index++) {
        var code = new StringBuilder(39);
        var sid = new StringBuilder(1024);
        uint sidLength = 1024;
        uint context;
        // NULL user SID: current user plus machine context, never other users.
        uint status = MsiEnumProductsExW(productCode, null, 7, index, code,
          out context, sid, ref sidLength);
        if (status == 259) return registrations.ToArray();
        if (status != 0) throw new InvalidOperationException(
          "Read-only MSI inventory failed with code " + status + ".");
        registrations.Add(new MsiRegistration {
          ProductCode=code.ToString(), Context=context, UserSid=sid.ToString()
        });
      }
      throw new InvalidOperationException("Unexpected MSI registration count.");
    }
  }
}
'@
    Add-Type -TypeDefinition $inventorySource -ErrorAction Stop
  }
  return [QContractQa.MsiInventory]::Enumerate($ProductCode)
}

function Assert-MsiRegistrationContext([object[]]$Registrations,[string]$ProductCode,[string]$CurrentSid,[bool]$Absent=$false) {
  if ($Absent) {
    if ($Registrations.Count -ne 0) { throw 'Uninstall left a Windows Installer product registration.' }
    return
  }
  if ($Registrations.Count -ne 1 -or $Registrations[0].ProductCode -ine $ProductCode -or
      [int]$Registrations[0].Context -notin @(1,2) -or $Registrations[0].UserSid -ine $CurrentSid) {
    throw 'Windows Installer did not register exactly this product for the current user without machine context.'
  }
}

function Assert-PayloadIntegrity {
  $path = Resolve-PayloadPath $installRoot $request.expected_manifest.path
  Assert-Hash $path $request.expected_manifest.sha256
  $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  if ($manifest.schema -ne 1 -or $manifest.version -cne $request.version -or @($manifest.files).Count -lt 1000) { throw 'Unexpected client integrity manifest.' }
  $seen = @{}
  foreach ($entry in $manifest.files) {
    if ($entry.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $entry.size -lt 0 -or $seen.ContainsKey($entry.path)) { throw 'Invalid integrity manifest entry.' }
    $file = Resolve-PayloadPath $installRoot $entry.path
    Assert-Hash $file $entry.sha256 $entry.size
    $seen[$entry.path] = $true
  }
  $seen[$request.expected_manifest.path] = $true
  $seen['installed.marker'] = $true
  foreach ($file in (Get-ChildItem -LiteralPath $installRoot -Recurse -File)) {
    $relative = $file.FullName.Substring($installRoot.Length+1).Replace('\','/')
    if (-not $seen.ContainsKey($relative)) { throw 'Installed payload contains an unmanifested file.' }
  }
  $result.payload_files_verified = @($manifest.files).Count
}

function Assert-SecondaryManifest([string]$ManifestPath,[string]$FilesRoot,[bool]$InstallPath) {
  $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
  if ($manifest.schema -ne 1) { throw 'Unsupported prerequisite manifest.' }
  foreach ($entry in $manifest.files) {
    $relative = $entry.path
    if ($InstallPath) { $relative = $entry.install_path }
    Assert-Hash (Resolve-PayloadPath $FilesRoot $relative) $entry.sha256 $entry.size
  }
  return $manifest
}

function Assert-Shortcut([string]$ShortcutPath) {
  if (-not (Test-Path -LiteralPath $ShortcutPath)) { throw 'Automatic shortcut is missing.' }
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($ShortcutPath)
  $hostPath = Join-Path $installRoot 'app\desktop_host\QContract.exe'
  if ($shortcut.TargetPath -ne $hostPath -or $shortcut.Arguments -ne '' -or
      $shortcut.WorkingDirectory.TrimEnd('\') -ne $installRoot) { throw 'Shortcut target, arguments or working directory is incorrect.' }
  $iconPath = ($shortcut.IconLocation -replace ',\s*-?\d+$','').Trim('"')
  if ($iconPath -ne $hostPath) {
    $cacheRoot = Join-Path ([Environment]::GetFolderPath('ApplicationData')) ('Microsoft\Installer\'+$installedProduct+'\')
    if (-not [IO.Path]::GetFullPath($iconPath).StartsWith($cacheRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Shortcut icon is outside its per-user MSI cache.' }
    $expectedIconHash = (Get-FileHash -LiteralPath (Join-Path $installRoot 'app\desktop_host\QContract.ico') -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Hash $iconPath $expectedIconHash
  }
  $propertyShell = New-Object -ComObject Shell.Application
  $item = $propertyShell.Namespace((Split-Path -Parent $ShortcutPath)).ParseName((Split-Path -Leaf $ShortcutPath))
  if ($item.ExtendedProperty('System.AppUserModel.ID') -ne 'QContract.Desktop') { throw 'Shortcut application ID is incorrect.' }
}

function Get-WebViewAclSnapshot([string]$Path,[string]$CurrentSid) {
  $descriptor = Get-Acl -LiteralPath $Path
  $selectedSids = @($CurrentSid,'S-1-5-18','S-1-5-32-544','S-1-15-2-1','S-1-15-2-2')
  $selectedRules = @($descriptor.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) |
    Where-Object { $_.IdentityReference.Value -in $selectedSids } | Select-Object -First 32 |
    ForEach-Object {
      [ordered]@{sid=$_.IdentityReference.Value;rights=[string]$_.FileSystemRights;
        rights_mask=[long]$_.FileSystemRights;type=[string]$_.AccessControlType;
        inherited=[bool]$_.IsInherited;propagation=[string]$_.PropagationFlags;
        inheritance=[string]$_.InheritanceFlags}
    })
  return [ordered]@{owner_sid=$descriptor.GetOwner([Security.Principal.SecurityIdentifier]).Value;
    dacl_protected=[bool]$descriptor.AreAccessRulesProtected;rules=$selectedRules}
}

function Assert-WebViewAcl([string]$Directory) {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  try { $currentSid = $identity.User.Value } finally { $identity.Dispose() }
  [long]$fullControl = [Security.AccessControl.FileSystemRights]::FullControl
  $items = @((Get-Item -LiteralPath $Directory)) + @(Get-ChildItem -LiteralPath $Directory -Recurse -Force)
  foreach ($item in $items) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'WebView runtime reparse point.' }
    $rules = (Get-Acl -LiteralPath $item.FullName).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    $currentUserRules = @($rules | Where-Object { $_.IdentityReference.Value -eq $currentSid })
    if (@($currentUserRules | Where-Object { $_.AccessControlType -eq 'Deny' }).Count) {
      throw 'WebView permissions deny access to the installing Windows user.'
    }
    [long]$currentUserRights = 0
    foreach ($rule in ($currentUserRules | Where-Object {
      $_.AccessControlType -eq 'Allow' -and
      -not ($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)
    })) { $currentUserRights = $currentUserRights -bor [long]$rule.FileSystemRights }
    # Windows may inherit the exact user's grant onto the root or descendants
    # rather than duplicate it. Administrators/SYSTEM membership must never
    # substitute for the installing user's own SID.
    if (($currentUserRights -band $fullControl) -ne $fullControl) {
      $relative = $item.FullName.Substring($Directory.TrimEnd('\').Length).TrimStart('\')
      if (-not $relative) { $relative = '.' }
      try {
        $result.webview_acl_failure = [ordered]@{relative_path=$relative;current_user_sid=$currentSid;
          item=(Get-WebViewAclSnapshot $item.FullName $currentSid);
          parent=(Get-WebViewAclSnapshot (Split-Path -Parent $item.FullName) $currentSid)}
      } catch {
        $result.webview_acl_failure = [ordered]@{relative_path=$relative;current_user_sid=$currentSid;
          diagnostic_error_type=$_.Exception.GetType().FullName}
      }
      throw 'WebView permissions lack the required full control for the installing Windows user.'
    }
    foreach ($sid in @('S-1-15-2-1','S-1-15-2-2')) {
      $allow = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid -and $_.AccessControlType -eq 'Allow' })
      [long]$rights = 0
      foreach ($rule in $allow) { $rights = $rights -bor [long]$rule.FileSystemRights }
      if (($rights -band [long][Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne [long][Security.AccessControl.FileSystemRights]::ReadAndExecute -or
          ($rights -band (-bnot [long]0x1200a9)) -ne 0) { throw 'WebView AppContainer permissions are missing or exceed read/execute.' }
    }
  }
  $result.webview_acl_items_verified = $items.Count
  $result.webview_current_user_acl_verified = $true
}

function Invoke-PythonJson([string]$Python,[string[]]$Arguments,[string]$ResultName) {
  $output = & $Python '-B' @Arguments
  if ($LASTEXITCODE -ne 0) { throw ('Synthetic Python check failed: ' + $ResultName) }
  $parsed = ($output -join "`n") | ConvertFrom-Json
  $parsed | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $resultRoot ($ResultName+'.json')) -Encoding UTF8
  return $parsed
}

try {
  $requestFile = Get-Item -LiteralPath $RequestPath
  if ($requestFile.Length -gt 65536) { throw 'Oversized candidate request.' }
  $request = Get-Content -LiteralPath $requestFile.FullName -Raw | ConvertFrom-Json
  if ($request.schema -ne 1 -or $request.ready -isnot [bool]) { throw 'Invalid candidate request schema.' }
  if (-not $request.ready) {
    $result.status = 'skipped'; $result.reason = 'Request is not approved for execution.'
    return
  }
  if ($request.version -cnotmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$' -or
      $request.asset_name -cne ('QContract-Setup-'+$request.version+'.msi') -or
      $request.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
      $request.release_id -notmatch '^[1-9][0-9]{0,15}$' -or $request.asset_id -notmatch '^[1-9][0-9]{0,15}$' -or
      $request.size -notmatch '^[1-9][0-9]{0,10}$' -or [long]$request.size -gt 2147483648 -or
      $request.expected_manifest.path -cne 'runtime/client-integrity.json' -or
      $request.expected_manifest.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Candidate request identity, size or hash is invalid.' }
  $result.candidate = [ordered]@{release_id=$request.release_id;asset_id=$request.asset_id;asset_name=$request.asset_name;
    version=$request.version;size=$request.size;sha256=$request.sha256;integrity_manifest_sha256=$request.expected_manifest.sha256}
  if (Test-Path -LiteralPath $dataRoot) { throw 'Disposable VM unexpectedly contains existing QContract data.' }
  if (Test-Path -LiteralPath $installRoot) { throw 'Disposable VM unexpectedly contains the default QContract installation directory.' }
  $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Q Contract.lnk'
  $menuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Q Contract\Q Contract.lnk'
  if ((Test-Path -LiteralPath $desktopShortcut) -or (Test-Path -LiteralPath $menuShortcut)) { throw 'Unexpected preexisting QContract shortcut.' }
  if ($StagedCandidatePath) {
    # The other job holds the draft-read credential. This fresh VM receives only
    # one same-run artifact; verify its expected fixed location and exact bytes.
    $expectedStagedPath = Resolve-PayloadPath $env:RUNNER_TEMP 'qcontract-msi-transfer/candidate.msi'
    if ([IO.Path]::GetFullPath($StagedCandidatePath) -ine $expectedStagedPath) { throw 'Unexpected staged candidate location.' }
    Assert-Hash $expectedStagedPath $request.sha256 ([long]$request.size)
    if (Test-Path -LiteralPath $candidatePath) { throw 'Candidate destination already exists.' }
    Copy-Item -LiteralPath $expectedStagedPath -Destination $candidatePath
    $result.candidate_transport = 'same-run-artifact-from-separate-fetch-job'
  } else {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $http = New-Object System.Net.Http.HttpClient($handler)
    $http.Timeout = [TimeSpan]::FromMinutes(10)
    try {
      $release = Get-ApiJson ('https://api.github.com/repos/'+$repository+'/releases/'+$request.release_id)
      if ($release.id -ne $request.release_id -or $release.draft -ne $true) { throw 'Candidate must belong to the exact draft release.' }
      $assets = @($release.assets | Where-Object { $_.id -eq $request.asset_id })
      if ($assets.Count -ne 1) { throw 'Candidate asset ID is absent or ambiguous.' }
      $asset = $assets[0]
      if ($asset.name -cne $request.asset_name -or $asset.size -ne $request.size -or $asset.state -ne 'uploaded' -or
          $asset.url -cne ('https://api.github.com/repos/'+$repository+'/releases/assets/'+$request.asset_id)) { throw 'Draft candidate metadata mismatch.' }
      if ($asset.PSObject.Properties.Name -contains 'digest') {
        if ($asset.digest -and $asset.digest -cne ('sha256:'+$request.sha256)) { throw 'GitHub asset digest mismatch.' }
      }
      Save-Candidate $asset.url ([long]$request.size)
    } finally {
      $http.Dispose(); $handler.Dispose(); $token=$null
      foreach ($variable in @('QA_GITHUB_TOKEN','GITHUB_TOKEN','GH_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
        [Environment]::SetEnvironmentVariable($variable,$null,'Process')
      }
    }
  }
  $token=$null
  foreach ($variable in @('QA_GITHUB_TOKEN','GITHUB_TOKEN','GH_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
    [Environment]::SetEnvironmentVariable($variable,$null,'Process')
  }
  Assert-Hash $candidatePath $request.sha256 ([long]$request.size)
  $result.candidate_hash_verified = $true
  Invoke-DefenderScan $candidatePath 'candidate'
  $installedProduct = Assert-MsiTables $candidatePath
  $result.product_code = $installedProduct
  Invoke-Msi 'install' 'install'
  if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'installed.marker')) -or
      (Get-Content -LiteralPath (Join-Path $installRoot 'installed.marker') -Raw) -notmatch '(?im)^Type\s*=\s*per-user\s*$' -or
      (Test-Path -LiteralPath (Join-Path $installRoot 'Data'))) { throw 'Per-user installed marker or data layout is invalid.' }
  $result.default_install_path_verified = $true
  $installIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  try { $installUserSid = $installIdentity.User.Value } finally { $installIdentity.Dispose() }
  $registrations = @(Get-MsiProductRegistrations $installedProduct)
  Assert-MsiRegistrationContext $registrations $installedProduct $installUserSid
  $result.per_user_registration_verified = $true
  $result.msi_install_context = [int]$registrations[0].Context
  $result.install_user_sid_matches = $true
  Assert-PayloadIntegrity
  Invoke-DefenderScan $installRoot 'payload'
  $prereqs = Assert-SecondaryManifest (Join-Path $installRoot 'runtime\prerequisites.json') $installRoot $true
  if ($prereqs.ready -ne $true -or $prereqs.runtime_network_required -ne $false -or $prereqs.architecture -ne 'x64') { throw 'Bundled runtime prerequisites are incomplete.' }
  $hostManifest = Assert-SecondaryManifest (Join-Path $installRoot 'app\desktop_host\host-manifest.json') (Join-Path $installRoot 'app\desktop_host') $false
  Assert-MicrosoftSignature (Join-Path $installRoot 'runtime\webview2\msedgewebview2.exe')
  Assert-MicrosoftSignature (Join-Path $installRoot 'app\desktop_host\WebView2Loader.dll')
  foreach ($vcFile in (Get-ChildItem -LiteralPath (Join-Path $installRoot 'runtime') -File -Filter '*.dll' |
      Where-Object { $_.Name -match '^(msvcp140.*|vcruntime140.*|concrt140|vcomp140|vcamp140|vccorlib140)\.dll$' })) {
    Assert-MicrosoftSignature $vcFile.FullName
  }
  $dotNet = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
  if ($dotNet.Release -lt 461808 -or $hostManifest.minimum_framework_release -ne 461808) { throw '.NET Framework prerequisite is not satisfied.' }
  Assert-Shortcut $desktopShortcut
  Assert-Shortcut $menuShortcut
  $result.desktop_shortcut_verified=$true; $result.start_menu_shortcut_verified=$true
  Assert-WebViewAcl (Join-Path $installRoot 'runtime\webview2')
  $python = Join-Path $installRoot 'runtime\python.exe'
  $systemPython = (Get-Command python.exe -CommandType Application | Select-Object -First 1).Source
  if ($systemPython.StartsWith($installRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Post-uninstall verifier must be independent of installed runtime.' }
  # This unique rule exists only in this disposable hosted VM, on the verified bundled worker.
  $firewallName = 'QContract-QA-offline-' + [guid]::NewGuid().ToString('N')
  New-NetFirewallRule -Name $firewallName -DisplayName $firewallName -Direction Outbound -Action Block -Program $python -Profile Any -Enabled True | Out-Null
  $firewall = Get-NetFirewallRule -Name $firewallName
  if ($firewall.Enabled -ne 'True' -or $firewall.Action -ne 'Block' -or $firewall.Direction -ne 'Outbound') { throw 'Disposable inference firewall block was not applied.' }
  if (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count) { throw 'Disposable VM firewall profiles must already be enabled.' }
  $result.offline_process_outbound_blocked=$true
  $native = Invoke-PythonJson $python @('-X','utf8',(Join-Path $PSScriptRoot 'runtime_probe.py'),$installRoot) 'native-runtime'
  if (-not $native.vc_import_closure -or -not $native.loaded_vc_app_local) { throw 'App-local native runtime closure failed.' }
  $hostDiag = Join-Path $workRoot 'host-diagnosis.json'
  $hostProcess = Start-Process -FilePath (Join-Path $installRoot 'app\desktop_host\QContract.exe') -ArgumentList @('--diagnose-json',('"'+$hostDiag+'"')) -WindowStyle Hidden -Wait -PassThru
  if ($hostProcess.ExitCode -ne 0) { throw 'Standalone host diagnosis failed.' }
  $hostDiagnosis = Get-Content -LiteralPath $hostDiag -Raw | ConvertFrom-Json
  foreach ($component in @('framework_ok','fixed_runtime_ready','loader_ready','sdk_ready','backend_ready')) {
    if (-not $hostDiagnosis.$component) { throw ('Standalone host component failed: '+$component) }
  }
  $result.standalone_host_diagnosis_verified=$true
  $diagnosis = Invoke-PythonJson $python @('-X','utf8',(Join-Path $installRoot 'app\server.py'),'--data-dir',$diagRoot,'--diagnose') 'backend-diagnosis'
  if ($diagnosis.version -cne $request.version -or -not $diagnosis.local_ai.ready -or $diagnosis.files.PSObject.Properties.Value -contains $false) { throw 'Installed backend or offline model diagnosis failed.' }
  $inference = Invoke-PythonJson $python @('-X','utf8',(Join-Path $PSScriptRoot 'smoke_runtime.py'),$installRoot) 'offline-inference'
  if (-not $inference.offline_inference_ok -or -not $inference.network_disabled) { throw 'Offline inference failed.' }
  $baseline = Join-Path $workRoot 'synthetic-baseline.json'
  $fixture = Join-Path $PSScriptRoot 'smoke_state.py'
  $null = Invoke-PythonJson $python @('-X','utf8',$fixture,'create',$dataRoot,$baseline) 'synthetic-created'
  Invoke-Msi 'reinstall' 'reinstall'
  Assert-PayloadIntegrity
  Assert-Shortcut $desktopShortcut
  $null = Invoke-PythonJson $python @('-X','utf8',$fixture,'verify',$dataRoot,$baseline) 'reinstall-data'
  Invoke-Msi 'uninstall' 'uninstall'
  $null = Invoke-PythonJson $systemPython @('-X','utf8',$fixture,'verify',$dataRoot,$baseline) 'uninstall-data'
  $remainingRegistrations = @(Get-MsiProductRegistrations $installedProduct)
  Assert-MsiRegistrationContext $remainingRegistrations $installedProduct $installUserSid $true
  $result.uninstall_registration_removed = $true
  if ((Test-Path -LiteralPath $desktopShortcut) -or (Test-Path -LiteralPath $menuShortcut) -or
      (Test-Path -LiteralPath (Join-Path $installRoot 'app\desktop_host\QContract.exe'))) { throw 'Uninstall left an installed product or shortcut.' }
  Assert-DefenderActive
  $result.data_preserved=$true; $result.synthetic_only=$true; $result.status='passed'
  # Passing this candidate job does not publish or clear the HP Wolf review gate.
  $result.candidate_vm_checks_passed=$true
} catch {
  $result.status='failed'
  # Errors are controlled harness messages. Do not serialize HTTP exceptions, signed URLs or session data.
  $result.failure = $_.Exception.Message
  throw
} finally {
  if ($firewallName) { Remove-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue }
  $token=$null; $env:QA_GITHUB_TOKEN=$null; $env:GITHUB_TOKEN=$null; $env:GH_TOKEN=$null
  $result.completed_utc = [DateTime]::UtcNow.ToString('o')
  $result | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $resultRoot 'result.json') -Encoding UTF8
}
