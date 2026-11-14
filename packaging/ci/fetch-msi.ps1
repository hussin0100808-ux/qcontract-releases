param([Parameter(Mandatory=$true)][string]$RequestPath)
# Credentialed fetch only. Never open MSI, install it, or run client code here.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repository='hussin0100808-ux/qcontract-releases'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne $repository -or
    $env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_JOB -ne 'fetch' -or -not $env:RUNNER_TEMP) {
  throw 'Fetch is restricted to the approved disposable hosted Windows fetch job.'
}
Add-Type -AssemblyName System.Net.Http
$transfer=Join-Path $env:RUNNER_TEMP 'qcontract-msi-transfer'
if (Test-Path -LiteralPath $transfer) { throw 'Transfer destination already exists.' }
New-Item -ItemType Directory -Path $transfer | Out-Null
$candidatePath=Join-Path $transfer 'candidate.msi'
$token=$env:QA_GITHUB_TOKEN
$request=$null

function Assert-Hash([string]$Path,[string]$Expected,[long]$Size=-1) {
  $item = Get-Item -LiteralPath $Path
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Nonregular payload file.' }
  if ($Size -ge 0 -and $item.Length -ne $Size) { throw 'Payload byte count mismatch.' }
  if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Expected) { throw 'Payload SHA256 mismatch.' }
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
      if ([int]$response.StatusCode -ne 200) { throw ('GitHub metadata refused HTTP '+[int]$response.StatusCode+'.') }
      if ($response.Content.Headers.ContentLength -gt 2097152) { throw 'Oversized GitHub metadata.' }
      $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      if ($body.Length -gt 2097152) { throw 'Oversized GitHub metadata.' }
      return $body | ConvertFrom-Json
    } finally { $response.Dispose() }
  } catch {
    if ($_.Exception.Message -match '^GitHub metadata refused HTTP [1-5][0-9]{2}\.$') { throw }
    throw 'GitHub metadata transport or size validation failed.'
  }
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


try {
  $expectedRequest=[IO.Path]::GetFullPath((Join-Path $env:GITHUB_WORKSPACE '.qa\msi-candidate-request.json'))
  if ([IO.Path]::GetFullPath($RequestPath) -ine $expectedRequest) { throw 'Unexpected request location.' }
  $requestFile = Get-Item -LiteralPath $RequestPath
  if ($requestFile.PSIsContainer -or ($requestFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Request must be a regular file.' }
  if ($requestFile.Length -gt 65536) { throw 'Oversized candidate request.' }
  $request = Get-Content -LiteralPath $requestFile.FullName -Raw | ConvertFrom-Json
  if ($request.schema -ne 1 -or $request.ready -isnot [bool]) { throw 'Invalid candidate request schema.' }
  if (-not $request.ready) {
    throw 'Request is not approved for candidate transfer.'
  }
  if ($request.version -cnotmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$' -or
      $request.asset_name -cne ('QContract-Setup-'+$request.version+'.msi') -or
      $request.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
      $request.release_id -notmatch '^[1-9][0-9]{0,15}$' -or $request.asset_id -notmatch '^[1-9][0-9]{0,15}$' -or
      $request.size -notmatch '^[1-9][0-9]{0,10}$' -or [long]$request.size -gt 2147483648 -or
      $request.expected_manifest.path -cne 'runtime/client-integrity.json' -or
      $request.expected_manifest.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Candidate request identity, size or hash is invalid.' }
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
    if ($asset.digest -cne ('sha256:'+$request.sha256)) { throw 'GitHub asset digest mismatch.' }
    Save-Candidate $asset.url ([long]$request.size)
  } finally {
    $http.Dispose(); $handler.Dispose(); $token=$null
    foreach ($variable in @('QA_GITHUB_TOKEN','GITHUB_TOKEN','GH_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
      [Environment]::SetEnvironmentVariable($variable,$null,'Process')
    }
  }
  Assert-Hash $candidatePath $request.sha256 ([long]$request.size)
  if (@(Get-ChildItem -LiteralPath $transfer -Force).Count -ne 1) { throw 'Unexpected transfer contents.' }
  [ordered]@{schema=1;candidate_sha256=$request.sha256;size=$request.size;release_id=$request.release_id;
    asset_id=$request.asset_id;draft_verified=$true;installer_opened=$false;product_executed=$false} | ConvertTo-Json
} finally {
  $token=$null
  foreach ($variable in @('QA_GITHUB_TOKEN','GITHUB_TOKEN','GH_TOKEN')) {
    [Environment]::SetEnvironmentVariable($variable,$null,'Process')
  }
}
