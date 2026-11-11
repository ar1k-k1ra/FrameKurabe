$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Net.Http

$toolsPath = Join-Path $PSScriptRoot 'tools'
$ffmpegPath = Join-Path $toolsPath 'ffmpeg.exe'
$avsPmodPath = Join-Path $toolsPath 'AvsPmod\AvsPmod.exe'
$ffms2Path = Join-Path $toolsPath 'FFMS2\ffms2.dll'
$mpvPath = Join-Path $toolsPath 'MPV\mpv.exe'
$sceneDetectPath = Join-Path $toolsPath 'scenedetect\scenedetect.exe'
$geckoDriverPath = Join-Path $toolsPath 'geckodriver\geckodriver.exe'
$chromeDriverPath = Join-Path $toolsPath 'chromedriver\chromedriver.exe'

function Read-PositiveInteger {
    param([string]$Prompt, [int]$Minimum = 1)

    while ($true) {
        $text = Read-Host $Prompt
        $value = 0
        if ([int]::TryParse($text, [ref]$value) -and $value -ge $Minimum) {
            return $value
        }

        Write-Host "Enter a whole number greater than or equal to $Minimum." -ForegroundColor Yellow
    }
}

function Read-VideoPath {
    param([int]$Number)

    while ($true) {
        $text = (Read-Host "Drag and drop video $Number here, then press Enter").Trim()
        if ($text.Length -ge 2 -and $text[0] -eq '"' -and $text[$text.Length - 1] -eq '"') {
            $text = $text.Substring(1, $text.Length - 2)
        }

        if ([System.IO.File]::Exists($text)) {
            return Get-Item -LiteralPath $text
        }

        Write-Host 'That path is not a file. Try again.' -ForegroundColor Yellow
    }
}

function ConvertTo-AvsString {
    param([string]$Value)

    return $Value.Replace('"', '\"')
}

function Read-YesNo {
    param([string]$Prompt)

    while ($true) {
        $answer = (Read-Host $Prompt).Trim()
        if ($answer -match '^(?i:y|yes)$') {
            return $true
        }
        if ($answer -match '^(?i:n|no)$') {
            return $false
        }
        Write-Host 'Enter Y or N.' -ForegroundColor Yellow
    }
}

function Read-RequiredString {
    param([string]$Prompt)

    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        Write-Host 'Enter a value; it cannot be blank.' -ForegroundColor Yellow
    }
}

function Add-SlowPicsTextField {
    param(
        [System.Net.Http.MultipartFormDataContent]$Content,
        [string]$Name,
        [string]$Value
    )

    $fieldContent = [System.Net.Http.StringContent]::new($Value, [System.Text.Encoding]::UTF8)
    $Content.Add($fieldContent, $Name)
}

function Get-SlowPicsResponseBody {
    param([System.Net.Http.HttpResponseMessage]$Response)

    return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
}

function Format-SlowPicsDiagnostic {
    param([string]$Body)

    if ($Body.Length -gt 1000) {
        return $Body.Substring(0, 1000) + '...'
    }
    return $Body
}

function Get-SlowPicsHttpError {
    param(
        [System.Net.Http.HttpResponseMessage]$Response,
        [string]$Action,
        [string]$Body
    )

    $status = "HTTP $([int]$Response.StatusCode) $($Response.ReasonPhrase)"
    if ($Body -match '(?i)cloudflare|cf-error-code|attention required') {
        return "Cloudflare rejected FrameKurabe's automated HTTP request while $Action ($status). This does not mean slow.pics is unavailable in your browser. No comparison was created or uploaded. Local TIFF and PNG exports are unchanged."
    }

    $diagnostic = Format-SlowPicsDiagnostic -Body $Body
    return "slow.pics returned an error while $Action ($status). $diagnostic"
}

function ConvertTo-SlowPicsFileLabel {
    param([string]$Value)

    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()
    $safeValue = $Value
    foreach ($character in $invalidCharacters) {
        $safeValue = $safeValue.Replace([string]$character, '_')
    }

    $safeValue = $safeValue.Trim().TrimEnd([char[]]@('.', ' '))
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        return 'Video'
    }

    return $safeValue
}

function Get-DefaultPrivateBrowser {
    $httpsUserChoice = Get-ItemProperty `
        -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' `
        -ErrorAction SilentlyContinue
    $programId = if ($null -ne $httpsUserChoice) { [string]$httpsUserChoice.ProgId } else { '' }

    $browser = switch -Regex ($programId) {
        '(?i)chromehtml' {
            [pscustomobject]@{ Executable = 'chrome.exe'; PrivateArgument = '--incognito'; Name = 'Google Chrome' }
            break
        }
        '(?i)mse(htm|dge)' {
            [pscustomobject]@{ Executable = 'msedge.exe'; PrivateArgument = '--inprivate'; Name = 'Microsoft Edge' }
            break
        }
        '(?i)firefoxurl' {
            [pscustomobject]@{ Executable = 'firefox.exe'; PrivateArgument = '-private-window'; Name = 'Mozilla Firefox' }
            break
        }
        '(?i)bravehtml' {
            [pscustomobject]@{ Executable = 'brave.exe'; PrivateArgument = '--incognito'; Name = 'Brave' }
            break
        }
        default { $null }
    }

    if ($null -eq $browser) {
        throw "The default HTTPS browser ('$programId') is not supported for private-window launch. Set Chrome, Edge, Firefox, or Brave as the Windows default browser."
    }

    $candidatePaths = @()
    foreach ($registryPath in @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\$($browser.Executable)",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\$($browser.Executable)"
    )) {
        $appPath = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($null -ne $appPath -and -not [string]::IsNullOrWhiteSpace([string]$appPath.'(default)')) {
            $candidatePaths += [string]$appPath.'(default)'
        }
    }

    $programFilesPaths = switch ($browser.Executable) {
        'chrome.exe' {
            @(
                (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
                (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
            )
        }
        'msedge.exe' {
            @(
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
            )
        }
        'firefox.exe' {
            @(
                (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe'),
                (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
            )
        }
        'brave.exe' {
            @(
                (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application\brave.exe'),
                (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
            )
        }
    }
    $candidatePaths += $programFilesPaths

    $command = Get-Command $browser.Executable -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $candidatePaths += $command.Source
    }

    foreach ($candidatePath in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and
            (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            return [pscustomobject]@{
                Path = $candidatePath
                PrivateArgument = $browser.PrivateArgument
                Name = $browser.Name
            }
        }
    }

    throw "Could not locate $($browser.Name) ($($browser.Executable)) to open slow.pics in a private window."
}

function Start-SlowPicsPrivateBrowser {
    $browser = Get-DefaultPrivateBrowser
    Start-Process -FilePath $browser.Path -ArgumentList @(
        $browser.PrivateArgument,
        'https://slow.pics/comparison'
    ) -ErrorAction Stop | Out-Null
    Write-Host "Opened slow.pics in a private $($browser.Name) window." -ForegroundColor Cyan
}

function Get-InstalledFirefoxPath {
    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe'),
        (Join-Path $env:LOCALAPPDATA 'Mozilla Firefox\firefox.exe')
    )
    foreach ($registryPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe'
    )) {
        $appPath = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($null -ne $appPath -and -not [string]::IsNullOrWhiteSpace([string]$appPath.'(default)')) {
            $candidatePaths += [string]$appPath.'(default)'
        }
    }

    foreach ($candidatePath in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and
            (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            return $candidatePath
        }
    }

    throw 'Firefox was not found.'
}

function Get-InstalledChromePath {
    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($registryPath in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )) {
        $appPath = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($null -ne $appPath -and -not [string]::IsNullOrWhiteSpace([string]$appPath.'(default)')) {
            $candidatePaths += [string]$appPath.'(default)'
        }
    }

    foreach ($candidatePath in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and
            (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            return $candidatePath
        }
    }

    throw 'Neither Firefox nor Google Chrome was found. Install one of these browsers to upload to slow.pics.'
}

function Get-CompatibleChromeDriverPath {
    param([string]$ChromePath)

    $chromeVersion = (Get-Item -LiteralPath $ChromePath -ErrorAction Stop).VersionInfo.ProductVersion
    if ($chromeVersion -notmatch '^\d+\.\d+\.\d+\.\d+') {
        throw "Could not read the installed Chrome version from '$ChromePath'."
    }
    $chromeBuild = $Matches[0]
    $chromeBuildPrefix = ($chromeBuild -split '\.')[0..2] -join '.'

    if (Test-Path -LiteralPath $chromeDriverPath -PathType Leaf) {
        $bundledVersionText = (& $chromeDriverPath --version 2>$null | Select-Object -First 1)
        if ($bundledVersionText -match 'ChromeDriver\s+(\d+\.\d+\.\d+\.\d+)') {
            $bundledBuildPrefix = ($Matches[1] -split '\.')[0..2] -join '.'
            if ($bundledBuildPrefix -eq $chromeBuildPrefix) {
                return $chromeDriverPath
            }
        }
    }

    $cacheRoot = Join-Path $env:LOCALAPPDATA 'FrameKurabe\drivers\chromedriver'
    $cachedDriver = Join-Path (Join-Path $cacheRoot $chromeBuild) 'chromedriver.exe'
    if (Test-Path -LiteralPath $cachedDriver -PathType Leaf) {
        return $cachedDriver
    }

    Write-Host "Finding the ChromeDriver matching installed Chrome $chromeBuild..." -ForegroundColor Cyan
    try {
        $buildMetadata = Invoke-RestMethod `
            -Uri 'https://googlechromelabs.github.io/chrome-for-testing/latest-patch-versions-per-build.json' `
            -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        throw "Could not check the official Chrome for Testing metadata for Chrome $chromeBuild. Check your internet connection. $($_.Exception.Message)"
    }

    $matchingBuild = $buildMetadata.builds.PSObject.Properties[$chromeBuildPrefix]
    $driverVersion = $null
    $driverDownload = $null
    $requiresExactBuild = $true
    if ($null -ne $matchingBuild) {
        $driverVersion = [string]$matchingBuild.Value.version
        $driverDownload = $matchingBuild.Value.downloads.chromedriver |
            Where-Object platform -eq 'win64' |
            Select-Object -First 1
    }

    if ($null -eq $driverDownload) {
        try {
            $milestone = ($chromeBuild -split '\.')[0]
            $milestoneMetadata = Invoke-RestMethod `
                -Uri 'https://googlechromelabs.github.io/chrome-for-testing/latest-patch-versions-per-milestone.json' `
                -TimeoutSec 30 -ErrorAction Stop
            $matchingMilestone = $milestoneMetadata.milestones.PSObject.Properties[$milestone]
            if ($null -ne $matchingMilestone) {
                $driverVersion = [string]$matchingMilestone.Value.version
                $driverDownload = $matchingMilestone.Value.downloads.chromedriver |
                    Where-Object platform -eq 'win64' |
                    Select-Object -First 1
                $requiresExactBuild = $false
            }
        }
        catch {
            throw "Could not find an official ChromeDriver for Chrome $chromeBuild. $($_.Exception.Message)"
        }
    }

    if ($null -eq $driverDownload -or
        $driverDownload.url -notmatch '^https://storage\.googleapis\.com/chrome-for-testing-public/\d+\.\d+\.\d+\.\d+/win64/chromedriver-win64\.zip$') {
        throw "Google's Chrome for Testing metadata does not list a supported Windows x64 ChromeDriver for Chrome $chromeBuild."
    }

    $temporaryRoot = Join-Path $env:TEMP ('FrameKurabe_ChromeDriver_' + [guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $temporaryRoot 'chromedriver.zip'
    $extractPath = Join-Path $temporaryRoot 'extracted'
    try {
        New-Item -ItemType Directory -Path $extractPath -Force -ErrorAction Stop | Out-Null
        Invoke-WebRequest -Uri $driverDownload.url -OutFile $zipPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop

        $downloadedDriver = Join-Path $extractPath 'chromedriver-win64\chromedriver.exe'
        if (-not (Test-Path -LiteralPath $downloadedDriver -PathType Leaf)) {
            throw "The official ChromeDriver archive for version $driverVersion did not contain chromedriver.exe."
        }
        $downloadedVersionText = (& $downloadedDriver --version 2>$null | Select-Object -First 1)
        if ($downloadedVersionText -notmatch 'ChromeDriver\s+(\d+\.\d+\.\d+\.\d+)') {
            throw "Could not verify the downloaded ChromeDriver version $driverVersion."
        }
        $downloadedVersion = $Matches[1]
        $downloadedBuildPrefix = ($downloadedVersion -split '\.')[0..2] -join '.'
        $downloadedMajor = ($downloadedVersion -split '\.')[0]
        $chromeMajor = ($chromeBuild -split '\.')[0]
        if (($requiresExactBuild -and $downloadedBuildPrefix -ne $chromeBuildPrefix) -or
            (-not $requiresExactBuild -and $downloadedMajor -ne $chromeMajor)) {
            throw "Downloaded ChromeDriver $($Matches[1]) does not match installed Chrome $chromeBuild."
        }

        $cacheDirectory = Split-Path -Parent $cachedDriver
        New-Item -ItemType Directory -Path $cacheDirectory -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $downloadedDriver -Destination $cachedDriver -Force -ErrorAction Stop
        Write-Host "Cached matching ChromeDriver $driverVersion for this user." -ForegroundColor Cyan
        return $cachedDriver
    }
    catch {
        throw "Could not prepare a ChromeDriver compatible with Chrome $chromeBuild. The bundled or downloaded driver could not be used. $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SlowPicsWebDriver {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body
    )

    $requestUri = $script:slowPicsWebDriverBaseUri + $Path
    if ($null -eq $Body) {
        return Invoke-RestMethod -Uri $requestUri -Method $Method -TimeoutSec 120 -ErrorAction Stop
    }

    $jsonBody = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
    return Invoke-RestMethod -Uri $requestUri -Method $Method -ContentType 'application/json; charset=utf-8' `
        -Body $jsonBody -TimeoutSec 120 -ErrorAction Stop
}

function Find-SlowPicsWebDriverElement {
    param(
        [string]$Using,
        [string]$Value
    )

    $response = Invoke-SlowPicsWebDriver -Method 'POST' `
        -Path ("/session/{0}/element" -f $script:slowPicsWebDriverSessionId) `
        -Body @{ using = $Using; value = $Value }
    $elementId = $response.value.'element-6066-11e4-a52e-4f735466cecf'
    if ([string]::IsNullOrWhiteSpace([string]$elementId)) {
        throw "The browser could not find a slow.pics form element: $Value"
    }
    return [string]$elementId
}

function Set-SlowPicsWebDriverInput {
    param(
        [string]$Selector,
        [string]$Value
    )

    $characters = [System.Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Value.Length; $index++) {
        if ([char]::IsHighSurrogate($Value[$index]) -and
            ($index + 1) -lt $Value.Length -and
            [char]::IsLowSurrogate($Value[$index + 1])) {
            $characters.Add($Value.Substring($index, 2))
            $index++
        }
        else {
            $characters.Add([string]$Value[$index])
        }
    }

    $lastError = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $isPresent = Invoke-SlowPicsWebDriverScript -Script @'
const element = document.querySelector(arguments[0]);
if (!element) return false;
element.scrollIntoView({ block: 'center' });
return true;
'@ -Arguments @($Selector)
            if (-not $isPresent) {
                throw "The field '$Selector' is not present in the current form."
            }
            $elementId = Find-SlowPicsWebDriverElement -Using 'css selector' -Value $Selector
            $null = Invoke-SlowPicsWebDriver -Method 'POST' `
                -Path ("/session/{0}/element/{1}/click" -f $script:slowPicsWebDriverSessionId, $elementId) `
                -Body @{}
            $clearKeys = [System.Collections.Generic.List[string]]::new()
            $clearKeys.Add([string][char]0xE009)
            $clearKeys.Add('a')
            $clearKeys.Add([string][char]0xE003)
            $clearKeys.Add([string][char]0xE000)
            $clearText = -join $clearKeys.ToArray()
            $null = Invoke-SlowPicsWebDriver -Method 'POST' `
                -Path ("/session/{0}/element/{1}/value" -f $script:slowPicsWebDriverSessionId, $elementId) `
                -Body @{ text = $clearText; value = @($clearKeys.ToArray()) }
            $elementId = Find-SlowPicsWebDriverElement -Using 'css selector' -Value $Selector
            $null = Invoke-SlowPicsWebDriver -Method 'POST' `
                -Path ("/session/{0}/element/{1}/value" -f $script:slowPicsWebDriverSessionId, $elementId) `
                -Body @{ text = $Value; value = @($characters.ToArray()) }

            $actualValue = Invoke-SlowPicsWebDriverScript -Script @'
return document.querySelector(arguments[0])?.value;
'@ -Arguments @($Selector)
            if ($actualValue -eq $Value) {
                return
            }
            $lastError = "The field retained '$actualValue' instead of '$Value'."
        }
        catch {
            $lastError = $_.Exception.Message
            if ($lastError -notmatch '(?i)stale element|no such element|not found in the current frame') {
                throw "Could not set the slow.pics form field '$Selector'. $lastError"
            }
        }
        Start-Sleep -Milliseconds 150
    }

    throw "Could not reliably set the slow.pics form field '$Selector' after several attempts. $lastError"
}

function Set-SlowPicsWebDriverSelect {
    param(
        [int]$Index,
        [string]$Value
    )

    $selectState = Invoke-SlowPicsWebDriverScript -Script @'
const select = document.querySelectorAll('select')[arguments[0]];
if (!select) return { found: false };
const targetIndex = Array.from(select.options).findIndex(option => option.value === arguments[1]);
if (targetIndex < 0) return { found: false };
const previousValue = select.value;
select.value = arguments[1];
select.dispatchEvent(new Event('input', { bubbles: true }));
select.dispatchEvent(new Event('change', { bubbles: true }));
return { found: true, value: select.value, previousValue };
'@ -Arguments @($Index, $Value)
    if (-not $selectState.found) {
        throw "The slow.pics dropdown $($Index + 1) does not contain the expected option '$Value'."
    }
    if ($selectState.value -ne $Value) {
        throw "The slow.pics dropdown $($Index + 1) did not select '$Value'; it remains '$($selectState.value)'."
    }
    if ($selectState.previousValue -eq $Value) {
        return
    }

    $saveVisible = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $saveVisible = Invoke-SlowPicsWebDriverScript -Script @'
return Array.from(document.querySelectorAll('#save-config.show a')).some(element =>
    element.innerText.trim().startsWith('Save') && element.getClientRects().length > 0
);
'@
        if ($saveVisible) {
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $saveVisible) {
        throw "slow.pics did not show its Save control after changing dropdown '$Value'."
    }

    $saveClicked = $false
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $saveElement = Find-SlowPicsWebDriverElement -Using 'css selector' -Value '#save-config.show a'
            $null = Invoke-SlowPicsWebDriver -Method 'POST' `
                -Path ("/session/{0}/element/{1}/click" -f $script:slowPicsWebDriverSessionId, $saveElement) `
                -Body @{}
            $saveClicked = $true
            break
        }
        catch {
            if ($_.Exception.Message -notmatch '(?i)stale element|no such element|not found in the current frame') {
                throw "Could not click slow.pics' Save control for '$Value'. $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $saveClicked) {
        throw "Could not click slow.pics' Save control for '$Value' because the control kept changing."
    }

    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $savePending = Invoke-SlowPicsWebDriverScript -Script @'
return Array.from(document.querySelectorAll('#save-config')).some(element =>
    element.classList.contains('show') && element.getClientRects().length > 0
);
'@
        if (-not $savePending) {
            return
        }
        Start-Sleep -Milliseconds 100
    }

    throw "slow.pics did not confirm saving the dropdown setting '$Value'."
}

function Invoke-SlowPicsWebDriverScript {
    param(
        [string]$Script,
        [object[]]$Arguments = @()
    )

    $response = Invoke-SlowPicsWebDriver -Method 'POST' `
        -Path ("/session/{0}/execute/sync" -f $script:slowPicsWebDriverSessionId) `
        -Body @{ script = $Script; args = @($Arguments) }
    return $response.value
}

function Wait-SlowPicsWebDriverElementCounts {
    param(
        [int]$ExpectedRows,
        [int]$ExpectedColumns
    )

    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $counts = Invoke-SlowPicsWebDriverScript -Script @'
return {
    rows: document.querySelectorAll('input[id^="comparisonName_"]').length,
    columns: document.querySelectorAll('input[id^="colName_"]').length
};
'@
        if ($counts.rows -eq $ExpectedRows -and $counts.columns -eq $ExpectedColumns) {
            return
        }
        Start-Sleep -Seconds 1
    }

    throw "slow.pics did not parse the selected TIFFs into the expected grid ($ExpectedRows rows by $ExpectedColumns columns). Review the visible browser form and staged upload files."
}

function Get-SlowPicsColumnPrefix {
    param([int]$Index)

    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $first = [int][Math]::Floor($Index / $alphabet.Length)
    $second = $Index % $alphabet.Length
    if ($first -ge $alphabet.Length) {
        throw 'slow.pics browser upload supports at most 676 video columns.'
    }
    return '{0}{1}' -f $alphabet[$first], $alphabet[$second]
}

function Start-SlowPicsBrowserUiUpload {
    param(
        [string]$OutputPath,
        [string]$CollectionName,
        [string[]]$VideoTitles,
        [int[]]$Frames,
        [object[]]$PendingExports
    )

    if ($PendingExports.Count -ne ($Frames.Count * $VideoTitles.Count)) {
        throw "The upload requires $($Frames.Count * $VideoTitles.Count) TIFF files, but $($PendingExports.Count) export records were provided."
    }

    $stagingDirectory = Join-Path $OutputPath ('FrameKurabe_slowpics_upload_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingDirectory -ErrorAction Stop | Out-Null
    $stagedFiles = @()
    $titleCounts = @{}
    for ($videoIndex = 0; $videoIndex -lt $VideoTitles.Count; $videoIndex++) {
        $safeTitle = ConvertTo-SlowPicsFileLabel -Value $VideoTitles[$videoIndex]
        if ($titleCounts.ContainsKey($safeTitle)) {
            $titleCounts[$safeTitle]++
            $safeTitle = '{0}_{1}' -f $safeTitle, $titleCounts[$safeTitle]
        }
        else {
            $titleCounts[$safeTitle] = 1
        }

        $columnPrefix = Get-SlowPicsColumnPrefix -Index $videoIndex
        for ($frameIndex = 0; $frameIndex -lt $Frames.Count; $frameIndex++) {
            $pendingExport = $PendingExports |
                Where-Object { $_.FrameIndex -eq $frameIndex -and $_.VideoIndex -eq $videoIndex } |
                Select-Object -First 1
            if ($null -eq $pendingExport -or -not (Test-Path -LiteralPath $pendingExport.TiffDestination -PathType Leaf)) {
                throw "The exported TIFF for frame $($Frames[$frameIndex]) and '$($VideoTitles[$videoIndex])' could not be found."
            }

            $stagedFile = Join-Path $stagingDirectory ('{0}_{1}_{2}.tiff' -f $columnPrefix, $safeTitle, $Frames[$frameIndex])
            try {
                New-Item -ItemType HardLink -Path $stagedFile -Target $pendingExport.TiffDestination -ErrorAction Stop | Out-Null
            }
            catch {
                Copy-Item -LiteralPath $pendingExport.TiffDestination -Destination $stagedFile -ErrorAction Stop
            }
            $stagedFiles += $stagedFile
        }
    }

    $driverProcess = $null
    $sessionCreated = $false
    $comparisonUrl = $null
    try {
        $browserName = 'Mozilla Firefox'
        $driverName = 'geckodriver'
        $firefoxPath = $null
        try {
            $firefoxPath = Get-InstalledFirefoxPath
        }
        catch {
            if ($_.Exception.Message -ne 'Firefox was not found.') {
                throw
            }
            $firefoxPath = $null
        }
        if ($null -ne $firefoxPath) {
            if (-not (Test-Path -LiteralPath $geckoDriverPath -PathType Leaf)) {
                throw "Mozilla geckodriver is missing: $geckoDriverPath"
            }
            $browserPath = $firefoxPath
            $selectedDriverPath = $geckoDriverPath
        }
        else {
            try {
                $browserPath = Get-InstalledChromePath
            }
            catch {
                throw $_.Exception.Message
            }
            $browserName = 'Google Chrome'
            $driverName = 'ChromeDriver'
            $selectedDriverPath = Get-CompatibleChromeDriverPath -ChromePath $browserPath
        }

        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $driverPort = $listener.LocalEndpoint.Port
        $listener.Stop()

        $driverArguments = if ($null -ne $firefoxPath) {
            @('--host', '127.0.0.1', '--port', [string]$driverPort, '--log', 'error')
        }
        else {
            @("--port=$driverPort", '--log-level=SEVERE')
        }
        $driverProcess = Start-Process -FilePath $selectedDriverPath `
            -ArgumentList $driverArguments `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
        $script:slowPicsWebDriverBaseUri = 'http://127.0.0.1:{0}' -f $driverPort

        $driverReady = $false
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            if ($driverProcess.HasExited) {
                throw "$driverName exited before startup completed (exit code $($driverProcess.ExitCode))."
            }
            try {
                $status = Invoke-RestMethod -Uri ($script:slowPicsWebDriverBaseUri + '/status') `
                    -Method Get -TimeoutSec 2 -ErrorAction Stop
                if ($status.value.ready) {
                    $driverReady = $true
                    break
                }
            }
            catch {
                Start-Sleep -Milliseconds 200
            }
        }
        if (-not $driverReady) {
            throw "$driverName did not become ready within 20 seconds."
        }

        $browserCapabilities = @{
            browserName = if ($null -ne $firefoxPath) { 'firefox' } else { 'chrome' }
            pageLoadStrategy = 'eager'
        }
        if ($null -ne $firefoxPath) {
            $browserCapabilities['moz:firefoxOptions'] = @{
                binary = $browserPath
                prefs = @{ 'browser.privatebrowsing.autostart' = $true }
            }
        }
        else {
            $browserCapabilities['goog:chromeOptions'] = @{
                binary = $browserPath
                args = @('--incognito', '--no-first-run', '--no-default-browser-check')
            }
        }
        $capabilities = @{
            capabilities = @{
                alwaysMatch = $browserCapabilities
            }
        }
        $session = Invoke-SlowPicsWebDriver -Method 'POST' -Path '/session' -Body $capabilities
        $script:slowPicsWebDriverSessionId = [string]$session.value.sessionId
        if ([string]::IsNullOrWhiteSpace($script:slowPicsWebDriverSessionId)) {
            throw "$browserName WebDriver did not return a session ID."
        }
        $sessionCreated = $true

        $null = Invoke-SlowPicsWebDriver -Method 'POST' `
            -Path ("/session/{0}/url" -f $script:slowPicsWebDriverSessionId) `
            -Body @{ url = 'https://slow.pics/comparison' }
        Write-Host "Opened slow.pics in a private $browserName window and preparing the upload form..." -ForegroundColor Cyan

        $formReady = $false
        $challengePrompted = $false
        for ($attempt = 0; $attempt -lt 150; $attempt++) {
            $pageState = Invoke-SlowPicsWebDriverScript -Script @'
return {
    ready: document.readyState,
    hasForm: !!document.querySelector('#upload-all') && !!document.querySelector('#collectionName'),
    title: document.title,
    text: (document.body && document.body.innerText || '').slice(0, 1000)
};
'@
            if ($pageState.hasForm) {
                $formReady = $true
                break
            }
            if (-not $challengePrompted -and $pageState.text -match '(?i)cloudflare|verify you are human|checking your browser|attention required') {
                Write-Host "The private $browserName window needs a Cloudflare check. Complete it in the browser; FrameKurabe will continue automatically when the upload form appears." -ForegroundColor Yellow
                $challengePrompted = $true
            }
            Start-Sleep -Seconds 2
        }
        if (-not $formReady) {
            throw "The slow.pics comparison form did not load in $browserName. Current page title: $($pageState.title)."
        }

        $uploadElement = Find-SlowPicsWebDriverElement -Using 'css selector' -Value '#upload-all'
        $uploadKeys = [System.Collections.Generic.List[string]]::new()
        $allStagedPaths = $stagedFiles -join "`n"
        for ($index = 0; $index -lt $allStagedPaths.Length; $index++) {
            $uploadKeys.Add([string]$allStagedPaths[$index])
        }
        $null = Invoke-SlowPicsWebDriver -Method 'POST' `
            -Path ("/session/{0}/element/{1}/value" -f $script:slowPicsWebDriverSessionId, $uploadElement) `
            -Body @{ text = $allStagedPaths; value = @($uploadKeys.ToArray()) }

        Wait-SlowPicsWebDriverElementCounts -ExpectedRows $Frames.Count -ExpectedColumns $VideoTitles.Count

        $null = Set-SlowPicsWebDriverInput -Selector '#collectionName' -Value $CollectionName
        Set-SlowPicsWebDriverSelect -Index 0 -Value 'LINK_ONLY'
        Set-SlowPicsWebDriverSelect -Index 1 -Value 'image/webp'
        $optimizeElement = Find-SlowPicsWebDriverElement -Using 'css selector' -Value '#optimize-images'
        $optimizeState = Invoke-SlowPicsWebDriverScript -Script @'
return document.querySelector('#optimize-images')?.checked;
'@
        if (-not $optimizeState) {
            $null = Invoke-SlowPicsWebDriver -Method 'POST' `
                -Path ("/session/{0}/element/{1}/click" -f $script:slowPicsWebDriverSessionId, $optimizeElement) `
                -Body @{}
        }

        for ($videoIndex = 0; $videoIndex -lt $VideoTitles.Count; $videoIndex++) {
            $null = Set-SlowPicsWebDriverInput -Selector ("#colName_{0}" -f $videoIndex) -Value $VideoTitles[$videoIndex]
        }
        for ($frameIndex = 0; $frameIndex -lt $Frames.Count; $frameIndex++) {
            $null = Set-SlowPicsWebDriverInput -Selector ("#comparisonName_{0}" -f $frameIndex) -Value ([string]$Frames[$frameIndex])
        }

        $formState = Invoke-SlowPicsWebDriverScript -Script @'
return {
    collectionName: document.querySelector('#collectionName')?.value,
    visibility: document.querySelectorAll('select')[0]?.value,
    format: document.querySelectorAll('select')[1]?.value,
    optimize: document.querySelector('#optimize-images')?.checked,
    rows: Array.from(document.querySelectorAll('input[id^="comparisonName_"]')).map(element => element.value),
    columns: Array.from(document.querySelectorAll('input[id^="colName_"]')).map(element => element.value),
    fileCount: document.querySelector('#upload-all')?.files.length
};
'@
        if ($formState.collectionName -ne $CollectionName -or
            $formState.visibility -ne 'LINK_ONLY' -or
            $formState.format -ne 'image/webp' -or
            -not $formState.optimize -or
            $formState.fileCount -ne $stagedFiles.Count) {
            $diagnostic = ConvertTo-Json -InputObject $formState -Depth 10 -Compress
            throw "The visible slow.pics form did not retain the requested title, visibility, WebP optimization, or TIFF selection. Observed form state: $diagnostic"
        }
        for ($videoIndex = 0; $videoIndex -lt $VideoTitles.Count; $videoIndex++) {
            if ($formState.columns[$videoIndex] -ne $VideoTitles[$videoIndex]) {
                throw "The slow.pics column title $($videoIndex + 1) did not match '$($VideoTitles[$videoIndex])'."
            }
        }
        for ($frameIndex = 0; $frameIndex -lt $Frames.Count; $frameIndex++) {
            if ([string]$formState.rows[$frameIndex] -ne [string]$Frames[$frameIndex]) {
                throw "The slow.pics row $($frameIndex + 1) did not match frame $($Frames[$frameIndex])."
            }
        }

        Write-Host 'Verified the comparison title, frame rows, video columns, link-only visibility, WebP format, and optimization setting.' -ForegroundColor Cyan
        $uploadButton = Find-SlowPicsWebDriverElement -Using 'xpath' -Value "//button[normalize-space(.)='Upload comparisons']"
        $null = Invoke-SlowPicsWebDriver -Method 'POST' `
            -Path ("/session/{0}/element/{1}/click" -f $script:slowPicsWebDriverSessionId, $uploadButton) `
            -Body @{}
        Write-Host 'Uploading through the visible slow.pics browser form...' -ForegroundColor Cyan

        $completionError = $null
        for ($attempt = 0; $attempt -lt 900; $attempt++) {
            Start-Sleep -Seconds 2
            try {
                $uploadState = Invoke-SlowPicsWebDriverScript -Script @'
return {
    url: location.href,
    title: document.title,
    text: (document.body && document.body.innerText || '').slice(0, 1500)
};
'@
            }
            catch {
                $completionError = $_.Exception.Message
                break
            }

            if ($uploadState.url -match '(?i)^https://slow\.pics/c/[A-Za-z0-9_-]+/?$') {
                $comparisonUrl = $uploadState.url.TrimEnd('/')
                break
            }

            if (($attempt % 10) -eq 0) {
                $percent = [Math]::Min(99, [int](100 * ($attempt + 1) / 900))
                Write-Progress -Activity 'Uploading comparison through slow.pics browser UI' `
                    -Status 'Waiting for TIFF uploads and WebP conversion' `
                    -PercentComplete $percent
            }
        }
        Write-Progress -Activity 'Uploading comparison through slow.pics browser UI' -Completed

        if ([string]::IsNullOrWhiteSpace($comparisonUrl)) {
            if (-not [string]::IsNullOrWhiteSpace($completionError)) {
                throw "The browser session ended before FrameKurabe could read the comparison URL. The upload may have completed; check the Firefox window and your slow.pics uploads. Staged TIFFs were retained at: $stagingDirectory. Browser error: $completionError"
            }
            throw "slow.pics did not confirm completion. Review the Firefox window. The staged TIFFs were retained at: $stagingDirectory"
        }

        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop
        Write-Host "The private $browserName window will close after the successful upload." -ForegroundColor Cyan
        return $comparisonUrl
    }
    catch {
        Write-Host "Browser upload failed. The staged TIFFs were retained at: $stagingDirectory" -ForegroundColor Red
        throw
    }
    finally {
        if ($sessionCreated) {
            try {
                $null = Invoke-SlowPicsWebDriver -Method 'DELETE' `
                    -Path ("/session/{0}" -f $script:slowPicsWebDriverSessionId) -Body $null
            }
            catch {
                if ([string]::IsNullOrWhiteSpace($comparisonUrl)) {
                    Write-Warning "Could not close the private Firefox WebDriver session cleanly: $($_.Exception.Message)"
                }
            }
            $script:slowPicsWebDriverSessionId = $null
        }
        if ($null -ne $driverProcess) {
            $driverProcess.Refresh()
            if (-not $driverProcess.HasExited) {
                Stop-Process -Id $driverProcess.Id -ErrorAction Stop
            }
            $driverProcess.Dispose()
        }
    }
}

function Start-SlowPicsBrowserFallback {
    param(
        [string]$OutputPath,
        [string]$CollectionName,
        [string[]]$VideoTitles,
        [int[]]$Frames,
        [object[]]$PendingExports
    )

    $stagingDirectory = Join-Path $OutputPath ('FrameKurabe_slowpics_upload_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingDirectory -ErrorAction Stop | Out-Null

    $safeTitles = @()
    $titleCounts = @{}
    foreach ($title in $VideoTitles) {
        $safeTitle = ConvertTo-SlowPicsFileLabel -Value $title
        if ($titleCounts.ContainsKey($safeTitle)) {
            $titleCounts[$safeTitle]++
            $safeTitle = '{0}_{1}' -f $safeTitle, $titleCounts[$safeTitle]
        }
        else {
            $titleCounts[$safeTitle] = 1
        }
        $safeTitles += $safeTitle
    }

    try {
        for ($frameIndex = 0; $frameIndex -lt $Frames.Count; $frameIndex++) {
            for ($videoIndex = 0; $videoIndex -lt $VideoTitles.Count; $videoIndex++) {
                $pendingExport = $PendingExports |
                    Where-Object { $_.FrameIndex -eq $frameIndex -and $_.VideoIndex -eq $videoIndex } |
                    Select-Object -First 1
                if ($null -eq $pendingExport -or -not (Test-Path -LiteralPath $pendingExport.TiffDestination -PathType Leaf)) {
                    throw "The exported TIFF for frame $($Frames[$frameIndex]) and '$($VideoTitles[$videoIndex])' could not be found."
                }

                $stagedFile = Join-Path $stagingDirectory ('{0}_{1}.tiff' -f $safeTitles[$videoIndex], $Frames[$frameIndex])
                try {
                    New-Item -ItemType HardLink -Path $stagedFile -Target $pendingExport.TiffDestination -ErrorAction Stop | Out-Null
                }
                catch {
                    Copy-Item -LiteralPath $pendingExport.TiffDestination -Destination $stagedFile -ErrorAction Stop
                }
            }
        }

        Write-Host ''
        Write-Host "Cloudflare blocked FrameKurabe's direct upload request. A browser-assisted upload is ready." -ForegroundColor Yellow
        Write-Host "Comparison title: $CollectionName"
        Write-Host "The TIFFs have been staged here: $stagingDirectory"
        Write-Host 'In slow.pics, enter the comparison title, then select every TIFF in this staging folder under Batch upload.'
        Write-Host 'The filenames group frames into rows and videos into columns. Confirm the frame numbers, rename columns as requested, and use the column arrows to restore input-video order if needed.'
        Write-Host 'Set Visibility to Only by link, keep Optimize images checked, choose WEBP, then click Upload comparisons.'
        Write-Host 'The staging TIFFs are hard links when supported, so the original exports remain unchanged.'

        Start-SlowPicsPrivateBrowser

        if (Read-YesNo 'Did slow.pics confirm the upload? Remove the staging folder? (y/n)') {
            $comparisonUrl = (Read-Host 'Paste the slow.pics comparison URL (optional)').Trim()
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop
            if ($comparisonUrl -match '^https://slow\.pics/c/[A-Za-z0-9_-]+/?$') {
                Write-Host "slow.pics comparison uploaded: $comparisonUrl" -ForegroundColor Green
            }
            else {
                Write-Host 'Temporary upload staging files removed. Original TIFF and PNG exports remain in the output directory.' -ForegroundColor Green
            }
        }
        else {
            Write-Host "Upload staging files were retained at: $stagingDirectory" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Browser-assisted upload setup failed. Staged files, if any, remain at: $stagingDirectory" -ForegroundColor Red
        throw
    }
}

function Publish-SlowPicsComparison {
    param(
        [string]$CollectionName,
        [string[]]$VideoTitles,
        [int[]]$Frames,
        [object[]]$PendingExports
    )

    if ($PendingExports.Count -ne ($Frames.Count * $VideoTitles.Count)) {
        throw "The upload requires $($Frames.Count * $VideoTitles.Count) TIFF files, but $($PendingExports.Count) export records were provided."
    }
    for ($frameIndex = 0; $frameIndex -lt $Frames.Count; $frameIndex++) {
        for ($videoIndex = 0; $videoIndex -lt $VideoTitles.Count; $videoIndex++) {
            $pendingExport = $PendingExports |
                Where-Object { $_.FrameIndex -eq $frameIndex -and $_.VideoIndex -eq $videoIndex } |
                Select-Object -First 1
            if ($null -eq $pendingExport -or -not (Test-Path -LiteralPath $pendingExport.TiffDestination -PathType Leaf)) {
                throw "The exported TIFF for frame $($Frames[$frameIndex]) and '$($VideoTitles[$videoIndex])' could not be found."
            }
        }
    }

    $siteUri = [Uri]'https://slow.pics'
    $cookieContainer = [System.Net.CookieContainer]::new()
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CookieContainer = $cookieContainer
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(15)
    $client.DefaultRequestHeaders.Accept.ParseAdd('*/*')
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('Origin', 'https://slow.pics')
    $client.DefaultRequestHeaders.Referrer = [Uri]'https://slow.pics/comparison'

    try {
        $bootstrapResponse = $client.GetAsync('https://slow.pics/comparison').GetAwaiter().GetResult()
        try {
            if (-not $bootstrapResponse.IsSuccessStatusCode) {
                $body = Get-SlowPicsResponseBody -Response $bootstrapResponse
                $message = Get-SlowPicsHttpError -Response $bootstrapResponse -Action 'establishing an upload session' -Body $body
                throw $message
            }
        }
        finally {
            $bootstrapResponse.Dispose()
        }

        $xsrfCookie = $cookieContainer.GetCookies($siteUri)['XSRF-TOKEN']
        if ($null -eq $xsrfCookie -or [string]::IsNullOrWhiteSpace($xsrfCookie.Value)) {
            throw 'slow.pics did not provide an XSRF token; the upload cannot continue.'
        }
        $xsrfToken = [Uri]::UnescapeDataString($xsrfCookie.Value)
        $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('X-XSRF-TOKEN', $xsrfToken)

        $browserId = [guid]::NewGuid().ToString()
        $comparisonContent = [System.Net.Http.MultipartFormDataContent]::new()
        try {
            Add-SlowPicsTextField -Content $comparisonContent -Name 'collectionName' -Value $CollectionName
            Add-SlowPicsTextField -Content $comparisonContent -Name 'hentai' -Value 'false'
            Add-SlowPicsTextField -Content $comparisonContent -Name 'optimize-images' -Value 'true'
            Add-SlowPicsTextField -Content $comparisonContent -Name 'browserId' -Value $browserId
            Add-SlowPicsTextField -Content $comparisonContent -Name 'public' -Value 'false'

            for ($frameIndex = 0; $frameIndex -lt $Frames.Count; $frameIndex++) {
                Add-SlowPicsTextField -Content $comparisonContent `
                    -Name ("comparisons[{0}].name" -f $frameIndex) `
                    -Value ([string]$Frames[$frameIndex])

                for ($videoIndex = 0; $videoIndex -lt $VideoTitles.Count; $videoIndex++) {
                    Add-SlowPicsTextField -Content $comparisonContent `
                        -Name ("comparisons[{0}].imageNames[{1}]" -f $frameIndex, $videoIndex) `
                        -Value $VideoTitles[$videoIndex]
                }
            }

            $createResponse = $client.PostAsync('https://slow.pics/upload/comparison', $comparisonContent).GetAwaiter().GetResult()
            try {
                $createBody = Get-SlowPicsResponseBody -Response $createResponse
                if (-not $createResponse.IsSuccessStatusCode) {
                    $message = Get-SlowPicsHttpError -Response $createResponse -Action 'creating the comparison' -Body $createBody
                    throw $message
                }
                $comparison = ConvertFrom-Json -InputObject $createBody -ErrorAction Stop
            }
            finally {
                $createResponse.Dispose()
            }
        }
        finally {
            $comparisonContent.Dispose()
        }

        $collectionUuidProperty = $comparison.PSObject.Properties['collectionUuid']
        $keyProperty = $comparison.PSObject.Properties['key']
        $imagesProperty = $comparison.PSObject.Properties['images']
        if ($null -eq $collectionUuidProperty -or $null -eq $keyProperty -or $null -eq $imagesProperty) {
            throw 'slow.pics returned an incomplete comparison response; no image uploads were started.'
        }
        $collectionUuid = [string]$collectionUuidProperty.Value
        $comparisonKey = [string]$keyProperty.Value
        $imageGroups = $imagesProperty.Value
        if ([string]::IsNullOrWhiteSpace($collectionUuid) -or
            [string]::IsNullOrWhiteSpace($comparisonKey) -or
            $null -eq $imageGroups) {
            throw 'slow.pics returned an incomplete comparison response; no image uploads were started.'
        }

        $comparisonUrl = 'https://slow.pics/c/{0}' -f [Uri]::EscapeDataString($comparisonKey)
        if ($imageGroups.Count -ne $Frames.Count) {
            throw "slow.pics returned image identifiers for $($imageGroups.Count) rows; expected $($Frames.Count). The created comparison may be incomplete: $comparisonUrl"
        }

        $totalUploads = $Frames.Count * $VideoTitles.Count
        $completedUploads = 0
        for ($frameIndex = 0; $frameIndex -lt $Frames.Count; $frameIndex++) {
            $imageIds = @($imageGroups[$frameIndex])
            if ($imageIds.Count -ne $VideoTitles.Count) {
                throw "slow.pics returned $($imageIds.Count) image identifiers for frame $($Frames[$frameIndex]); expected $($VideoTitles.Count). The created comparison may be incomplete: $comparisonUrl"
            }

            for ($videoIndex = 0; $videoIndex -lt $VideoTitles.Count; $videoIndex++) {
                $pendingExport = $PendingExports |
                    Where-Object { $_.FrameIndex -eq $frameIndex -and $_.VideoIndex -eq $videoIndex } |
                    Select-Object -First 1
                if ($null -eq $pendingExport -or -not (Test-Path -LiteralPath $pendingExport.TiffDestination -PathType Leaf)) {
                    throw "The exported TIFF for frame $($Frames[$frameIndex]) and '$($VideoTitles[$videoIndex])' could not be found. The created comparison may be incomplete: $comparisonUrl"
                }

                $imageId = [string]$imageIds[$videoIndex]
                if ([string]::IsNullOrWhiteSpace($imageId)) {
                    throw "slow.pics returned an empty image identifier for frame $($Frames[$frameIndex]) and '$($VideoTitles[$videoIndex])'. The created comparison may be incomplete: $comparisonUrl"
                }

                $uploadContent = [System.Net.Http.MultipartFormDataContent]::new()
                try {
                    Add-SlowPicsTextField -Content $uploadContent -Name 'collectionUuid' -Value $collectionUuid
                    Add-SlowPicsTextField -Content $uploadContent -Name 'imageUuid' -Value $imageId
                    Add-SlowPicsTextField -Content $uploadContent -Name 'browserId' -Value $browserId

                    $imageStream = [System.IO.File]::OpenRead($pendingExport.TiffDestination)
                    $imageContent = [System.Net.Http.StreamContent]::new($imageStream)
                    $imageContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('image/tiff')
                    $uploadContent.Add($imageContent, 'file', [System.IO.Path]::GetFileName($pendingExport.TiffDestination))

                    $uploadResponse = $client.PostAsync('https://slow.pics/upload/image', $uploadContent).GetAwaiter().GetResult()
                    try {
                        $uploadBody = (Get-SlowPicsResponseBody -Response $uploadResponse).Trim()
                        if (-not $uploadResponse.IsSuccessStatusCode) {
                            $message = Get-SlowPicsHttpError -Response $uploadResponse -Action "uploading '$($pendingExport.TiffDestination)'" -Body $uploadBody
                            throw $message
                        }
                        if (-not [string]::IsNullOrWhiteSpace($uploadBody) -and $uploadBody -ne 'OK') {
                            $diagnostic = Format-SlowPicsDiagnostic -Body $uploadBody
                            throw "slow.pics returned an unexpected response for '$($pendingExport.TiffDestination)': $diagnostic"
                        }
                    }
                    finally {
                        $uploadResponse.Dispose()
                    }
                }
                catch {
                    throw "Upload failed for frame $($Frames[$frameIndex]) and '$($VideoTitles[$videoIndex])'. The comparison may be incomplete: $comparisonUrl. $($_.Exception.Message)"
                }
                finally {
                    $uploadContent.Dispose()
                }

                $completedUploads++
                Write-Progress -Activity 'Uploading TIFF frames to slow.pics' `
                    -Status ("{0} of {1} images uploaded" -f $completedUploads, $totalUploads) `
                    -PercentComplete ([int](100 * $completedUploads / $totalUploads))
            }
        }
        Write-Progress -Activity 'Uploading TIFF frames to slow.pics' -Completed
        return $comparisonUrl
    }
    finally {
        $client.Dispose()
    }
}

function Quote-ProcessArgument {
    param([string]$Argument)

    return '"' + $Argument.Replace('"', '\"') + '"'
}

function Get-SceneCutSuggestions {
    param(
        [System.IO.FileInfo]$Video,
        [string]$WorkingDirectory
    )

    $csvPath = Join-Path $WorkingDirectory 'source-scenes.csv'
    $stdoutPath = Join-Path $WorkingDirectory 'scene-detection.stdout.log'
    $stderrPath = Join-Path $WorkingDirectory 'scene-detection.stderr.log'
    Write-Host 'Detecting scene changes in the source video (PySceneDetect adaptive mode)...' -ForegroundColor Cyan
    $detectorArguments = @(
        '--input', $Video.FullName,
        '--output', $WorkingDirectory,
        '--min-scene-len', '0s',
        'detect-adaptive',
        'list-scenes',
        '--filename', 'source-scenes.csv',
        '--quiet'
    )
    $quotedArguments = $detectorArguments | ForEach-Object { Quote-ProcessArgument $_ }
    try {
        $detectorProcess = Start-Process -FilePath $sceneDetectPath `
            -ArgumentList ($quotedArguments -join ' ') `
            -Wait -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath
    }
    catch {
        throw "Could not start PySceneDetect for '$($Video.FullName)': $($_.Exception.Message)"
    }
    if ($detectorProcess.ExitCode -ne 0) {
        $diagnostics = @()
        foreach ($logPath in @($stderrPath, $stdoutPath)) {
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                $diagnostics += Get-Content -LiteralPath $logPath -Tail 20
            }
        }
        $diagnosticText = $diagnostics -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($diagnosticText)) {
            $diagnosticText = 'PySceneDetect returned no diagnostic output.'
        }
        throw "Scene detection failed for '$($Video.FullName)' (exit code $($detectorProcess.ExitCode)). $diagnosticText"
    }
    if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) {
        $diagnostics = @()
        foreach ($logPath in @($stderrPath, $stdoutPath)) {
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                $diagnostics += Get-Content -LiteralPath $logPath -Tail 20
            }
        }
        $diagnosticText = $diagnostics -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($diagnosticText)) {
            $diagnosticText = 'PySceneDetect exited successfully but produced no scene CSV or diagnostic output.'
        }
        throw "Scene detection produced no scene list for '$($Video.FullName)'. $diagnosticText"
    }

    $csvLines = Get-Content -LiteralPath $csvPath
    if ($csvLines.Count -lt 2) {
        return @()
    }

    $sceneRows = @($csvLines | Select-Object -Skip 1 | ConvertFrom-Csv)
    $cutFrames = @(
        $sceneRows |
            Where-Object { $_.'Scene Number' -ne '1' } |
            ForEach-Object {
                $oneBasedFrame = 0
                if ([int]::TryParse($_.'Start Frame', [ref]$oneBasedFrame) -and $oneBasedFrame -gt 1) {
                    $oneBasedFrame - 1
                }
            } |
            Sort-Object -Unique
    )

    if ($cutFrames.Count -le 5) {
        return $cutFrames
    }

    $suggestions = @()
    for ($index = 0; $index -lt 5; $index++) {
        $candidateIndex = [int][Math]::Round($index * ($cutFrames.Count - 1) / 4, 0, [MidpointRounding]::AwayFromZero)
        $suggestions += $cutFrames[$candidateIndex]
    }
    return @($suggestions | Sort-Object -Unique)
}

function Write-MpvFrameJumpScript {
    param([string]$Path)

    $script = @'
local mp = require "mp"

local active = false
local digits = ""
local digit_bindings = {}

local function display()
    mp.osd_message("Jump to zero-based frame: " .. digits .. "  (Enter=go, Esc=cancel)", 3600)
end

local function stop_input()
    active = false
    digits = ""
    for _, name in ipairs(digit_bindings) do
        mp.remove_key_binding(name)
    end
    digit_bindings = {}
end

local function finish_input()
    local frame = tonumber(digits)
    if frame == nil then
        stop_input()
        mp.osd_message("Frame jump cancelled.", 2)
        return
    end

    local fps = mp.get_property_number("container-fps")
    if fps == nil or fps <= 0 then
        fps = mp.get_property_number("estimated-vf-fps")
    end
    if fps == nil or fps <= 0 then
        stop_input()
        mp.osd_message("Cannot jump by frame: frame rate is unavailable.", 3)
        return
    end

    mp.commandv("seek", string.format("%.9f", frame / fps), "absolute+exact")
    stop_input()
    mp.osd_message("Seeking to frame " .. frame, 2)
end

local function begin_input()
    if active then
        return
    end
    active = true
    digits = ""
    for number = 0, 9 do
        local digit = tostring(number)
        local key_digit = digit
        local name = "frame-jump-digit-" .. digit
        table.insert(digit_bindings, name)
        mp.add_forced_key_binding(digit, name, function()
            digits = digits .. key_digit
            display()
        end)
    end

    table.insert(digit_bindings, "frame-jump-enter")
    mp.add_forced_key_binding("ENTER", "frame-jump-enter", finish_input)
    table.insert(digit_bindings, "frame-jump-backspace")
    mp.add_forced_key_binding("BS", "frame-jump-backspace", function()
        digits = digits:sub(1, -2)
        display()
    end)
    table.insert(digit_bindings, "frame-jump-cancel")
    mp.add_forced_key_binding("ESC", "frame-jump-cancel", function()
        stop_input()
        mp.osd_message("Frame jump cancelled.", 2)
    end)
    display()
end

mp.add_key_binding("g", "frame-jump", begin_input)
'@
    [System.IO.File]::WriteAllText($Path, $script, [System.Text.Encoding]::ASCII)
}

function Start-ComparisonPlayer {
    param(
        [System.IO.FileInfo]$Video,
        [string]$Title,
        [string]$LuaScript,
        [string]$Geometry,
        [string]$LogPath
    )

    $arguments = @(
        '--no-config',
        '--no-terminal',
        '--no-input-terminal',
        '--force-window=immediate',
        '--pause',
        '--start=0',
        '--no-audio',
        '--osd-level=3',
        ('--geometry={0}' -f $Geometry),
        '--osd-status-msg=Frame: ${estimated-frame-number}',
        ('--title={0}' -f $Title),
        ('--script={0}' -f $LuaScript),
        ('--log-file={0}' -f $LogPath),
        $Video.FullName
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $mpvPath
    $startInfo.Arguments = (($arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' ')
    $startInfo.WorkingDirectory = Split-Path -Parent $mpvPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) {
        throw "Could not start MPV for '$($Video.FullName)'."
    }

    return $process
}

if (-not (Test-Path -LiteralPath $ffmpegPath -PathType Leaf)) {
    throw "ffmpeg.exe was not found in the tools folder: $ffmpegPath"
}
if (-not (Test-Path -LiteralPath $avsPmodPath -PathType Leaf)) {
    throw "AvsPmod.exe was not found: $avsPmodPath"
}
if (-not (Test-Path -LiteralPath $ffms2Path -PathType Leaf)) {
    throw "FFMS2's AviSynth plugin was not found: $ffms2Path"
}
$env:PATH = [string]::Join(';', @(
    (Join-Path $toolsPath 'AviSynth'),
    (Join-Path $toolsPath 'FFMS2'),
    $env:PATH
))

$defaultOutputPath = [Environment]::GetFolderPath('MyPictures')
if ([string]::IsNullOrWhiteSpace($defaultOutputPath)) {
    $defaultOutputPath = Join-Path $HOME 'Pictures'
}

$previewDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('FrameKurabe_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $previewDirectory | Out-Null
$exportTempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('FrameKurabeExport_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $exportTempDirectory | Out-Null

$exportsCompleted = $false
try {
    Write-Host ''
    Write-Host 'FrameKurabe - video frame comparison' -ForegroundColor Cyan
    Write-Host 'Frame indices are zero-based: the first video frame is 0.'
    Write-Host 'For each selected frame, the script saves a 16-bit RGB TIFF and a 16-bit RGB PNG.'
    Write-Host ''

    while ($true) {
        $outputPathInput = (Read-Host "Output directory (leave blank for Pictures: $defaultOutputPath)").Trim()
        if ($outputPathInput.Length -ge 2 -and $outputPathInput[0] -eq '"' -and $outputPathInput[$outputPathInput.Length - 1] -eq '"') {
            $outputPathInput = $outputPathInput.Substring(1, $outputPathInput.Length - 2)
        }

        $requestedOutputPath = if ([string]::IsNullOrWhiteSpace($outputPathInput)) {
            $defaultOutputPath
        }
        else {
            $outputPathInput
        }

        try {
            $outputPath = [System.IO.Path]::GetFullPath($requestedOutputPath)
            if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
                throw "The output path is a file, not a directory: $outputPath"
            }
            if (-not (Test-Path -LiteralPath $outputPath -PathType Container)) {
                New-Item -ItemType Directory -Path $outputPath -Force -ErrorAction Stop | Out-Null
            }
            break
        }
        catch {
            Write-Host "Could not use that output directory: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $fileCount = Read-PositiveInteger 'How many video files do you want to compare?' 2
    $videos = @()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($index = 1; $index -le $fileCount; $index++) {
        $video = Read-VideoPath $index
        $resolvedPath = [System.IO.Path]::GetFullPath($video.FullName)
        if (-not $seenPaths.Add($resolvedPath)) {
            Write-Host 'That file was already selected. Choose a different file for each comparison.' -ForegroundColor Yellow
            $index--
            continue
        }

        $videos += Get-Item -LiteralPath $resolvedPath
    }

    $frameOffsets = [int[]]::new($videos.Count)
    $hasFrameDelays = Read-YesNo 'Do the videos have frame delays that need alignment? (y/n)'
    if ($hasFrameDelays) {
        if (-not (Test-Path -LiteralPath $mpvPath -PathType Leaf)) {
            throw "mpv.exe was not found: $mpvPath"
        }
        if (-not (Test-Path -LiteralPath $sceneDetectPath -PathType Leaf)) {
            throw "scenedetect.exe was not found: $sceneDetectPath"
        }

        $suggestedFrames = @(Get-SceneCutSuggestions -Video $videos[0] -WorkingDirectory $previewDirectory)
        if ($suggestedFrames.Count -eq 0) {
            Write-Host 'No scene cuts were detected; use frame jump and frame stepping to find matching frames manually.' -ForegroundColor Yellow
        }
        else {
            Write-Host ''
            Write-Host 'Suggested source frame numbers at scene changes (zero-based):' -ForegroundColor Cyan
            Write-Host ($suggestedFrames -join ', ')
        }
        Write-Host 'In either MPV window press g, type a frame number, then Enter to jump; use . / , to step one frame forward / backward.'
        Write-Host 'Frame-number jumps use the video frame rate; use single-frame stepping to fine-tune variable-frame-rate videos.'
        $mpvLuaPath = Join-Path $previewDirectory 'frame-jump.lua'
        Write-MpvFrameJumpScript -Path $mpvLuaPath

        for ($videoIndex = 1; $videoIndex -lt $videos.Count; $videoIndex++) {
            $comparisonVideo = $videos[$videoIndex]
            Write-Host ''
            Write-Host ("Align the source with video {0}/{1}: {2}" -f ($videoIndex + 1), $videos.Count, $comparisonVideo.Name) -ForegroundColor Green
            Write-Host 'Both windows open paused at the start. Match the same content, then close both windows.'
            $sourceLog = Join-Path $previewDirectory ('mpv_source_{0}.log' -f $videoIndex)
            $comparisonLog = Join-Path $previewDirectory ('mpv_compare_{0}.log' -f $videoIndex)
            $sourcePlayer = $null
            $comparisonPlayer = $null
            try {
                $sourcePlayer = Start-ComparisonPlayer -Video $videos[0] -Title ("SOURCE - {0}" -f $videos[0].Name) -LuaScript $mpvLuaPath -Geometry '50%x50%+0+0' -LogPath $sourceLog
                $comparisonPlayer = Start-ComparisonPlayer -Video $comparisonVideo -Title ("COMPARE - {0}" -f $comparisonVideo.Name) -LuaScript $mpvLuaPath -Geometry '50%x50%+50%+0' -LogPath $comparisonLog
            }
            catch {
                foreach ($player in @($sourcePlayer, $comparisonPlayer)) {
                    if ($null -ne $player -and -not $player.HasExited) {
                        $player.Kill()
                        $player.WaitForExit()
                    }
                }
                throw
            }

            try {
                $sourcePlayer.WaitForExit()
                $comparisonPlayer.WaitForExit()
                if ($sourcePlayer.ExitCode -ne 0) {
                    $details = if (Test-Path -LiteralPath $sourceLog) { (Get-Content -LiteralPath $sourceLog -Tail 15) -join [Environment]::NewLine } else { 'No MPV log was created.' }
                    throw "The source MPV preview exited with code $($sourcePlayer.ExitCode). $details"
                }
                if ($comparisonPlayer.ExitCode -ne 0) {
                    $details = if (Test-Path -LiteralPath $comparisonLog) { (Get-Content -LiteralPath $comparisonLog -Tail 15) -join [Environment]::NewLine } else { 'No MPV log was created.' }
                    throw "The MPV preview for '$($comparisonVideo.Name)' exited with code $($comparisonPlayer.ExitCode). $details"
                }
            }
            finally {
                $sourcePlayer.Dispose()
                $comparisonPlayer.Dispose()
            }

            $sourceMatchFrame = Read-PositiveInteger 'Enter the matching SOURCE frame number (zero-based)' 0
            $comparisonMatchFrame = Read-PositiveInteger ("Enter the matching frame number in {0} (zero-based)" -f $comparisonVideo.Name) 0
            $frameOffsets[$videoIndex] = $comparisonMatchFrame - $sourceMatchFrame
            Write-Host ('Frame alignment for {0}: source frame + ({1})' -f $comparisonVideo.Name, $frameOffsets[$videoIndex]) -ForegroundColor Cyan
        }

        Write-Host ''
        Write-Host 'Enter the source frame numbers to export. The fixed alignment offset will be applied to each comparison video.' -ForegroundColor Cyan
    }

    Write-Host ''
    Write-Host 'Opening the first video in AvsPmod. The overlay shows zero-based frame indices; you can leave the preview open.' -ForegroundColor Cyan
    $previewVideo = $videos[0]
    $avsPath = Join-Path $previewDirectory 'preview.avs'
    $cachePath = Join-Path $previewDirectory 'preview.ffindex'
    $escapedVideoPath = ConvertTo-AvsString $previewVideo.FullName
    $escapedCachePath = ConvertTo-AvsString $cachePath
    $escapedPluginPath = ConvertTo-AvsString $ffms2Path

    $avsContent = @"
LoadPlugin("$escapedPluginPath")
clip = FFVideoSource("$escapedVideoPath", cachefile="$escapedCachePath")
clip.ShowFrameNumber()
"@
    [System.IO.File]::WriteAllText($avsPath, $avsContent, [System.Text.Encoding]::Default)
    Start-Process -FilePath $avsPmodPath -ArgumentList ('"{0}"' -f $avsPath)

    Write-Host ''
    $frameCount = Read-PositiveInteger 'How many frame numbers do you want to export?' 1
    $frames = @()
    $seenFrames = [System.Collections.Generic.HashSet[int]]::new()

    for ($index = 1; $index -le $frameCount; $index++) {
        while ($true) {
            $frame = Read-PositiveInteger "Enter frame number $index (zero-based)" 0
            if ($seenFrames.Add($frame)) {
                $frames += $frame
                break
            }

            Write-Host 'That frame number is already listed. Enter a different frame.' -ForegroundColor Yellow
        }
    }

    $frames = @($frames | Sort-Object)
    $outputDirectories = @()
    $outputNameCounts = @{}
    for ($index = 0; $index -lt $videos.Count; $index++) {
        $video = $videos[$index]
        $outputName = $video.Name
        if ($outputNameCounts.ContainsKey($outputName)) {
            $outputNameCounts[$outputName]++
            $outputName = '{0} ({1})' -f $video.Name, $outputNameCounts[$video.Name]
        }
        else {
            $outputNameCounts[$outputName] = 1
        }

        $tiffDirectory = Join-Path $outputPath ($outputName + '.tiff')
        $pngDirectory = Join-Path $outputPath ($outputName + '.png')
        $mappedFrames = @($frames | ForEach-Object { $_ + $frameOffsets[$index] })
        if ($mappedFrames | Where-Object { $_ -lt 0 }) {
            throw "The frame offset for '$($video.Name)' maps a selected source frame below zero."
        }
        $outputDirectories += [pscustomobject]@{
            Video = $video
            Tiff = $tiffDirectory
            Png = $pngDirectory
            FrameOffset = $frameOffsets[$index]
            FrameNumbers = $mappedFrames
        }
    }
    $pendingExports = @()

    for ($outputIndex = 0; $outputIndex -lt $outputDirectories.Count; $outputIndex++) {
        $output = $outputDirectories[$outputIndex]
        $stagingDirectory = Join-Path $exportTempDirectory ('video_{0}' -f ($outputIndex + 1))
        $stagingTiffDirectory = Join-Path $stagingDirectory 'tiff'
        $stagingPngDirectory = Join-Path $stagingDirectory 'png'
        New-Item -ItemType Directory -Path $stagingTiffDirectory,$stagingPngDirectory | Out-Null

        for ($frameIndex = 0; $frameIndex -lt $output.FrameNumbers.Count; $frameIndex++) {
            $frame = $output.FrameNumbers[$frameIndex]
            $frameTag = '{0:D8}' -f $frame
            $stagingFrameTag = '{0:D8}' -f $frameIndex
            $stagingTiffPath = Join-Path $stagingTiffDirectory ('frame_{0}.tiff' -f $stagingFrameTag)
            $stagingPngPath = Join-Path $stagingPngDirectory ('frame_{0}.png' -f $stagingFrameTag)
            $outputFileBase = '{0}_{1}' -f $output.Video.BaseName, $frameTag

            $pendingExports += [pscustomobject]@{
                VideoIndex = $outputIndex
                FrameIndex = $frameIndex
                Frame = $frame
                TiffSource = $stagingTiffPath
                PngSource = $stagingPngPath
                TiffDestination = Join-Path $output.Tiff ($outputFileBase + '.tiff')
                PngDestination = Join-Path $output.Png ($outputFileBase + '.png')
            }
        }
    }

    $existingOutputs = @(
        $pendingExports | ForEach-Object {
            if ((Test-Path -LiteralPath $_.TiffDestination) -or (Test-Path -LiteralPath $_.PngDestination)) {
                $_.TiffDestination
                $_.PngDestination
            }
        }
    )
    if ($existingOutputs.Count -gt 0) {
        Write-Host ''
        Write-Host 'Some selected output images already exist and would be overwritten.' -ForegroundColor Yellow
        $overwrite = Read-Host 'Continue and overwrite them? (y/N)'
        if ($overwrite -notmatch '^(?i)y(es)?$') {
            Write-Host 'Export cancelled.'
            return
        }
    }

    foreach ($output in $outputDirectories) {
        New-Item -ItemType Directory -Path $output.Tiff -Force | Out-Null
        New-Item -ItemType Directory -Path $output.Png -Force | Out-Null
    }

    foreach ($outputIndex in 0..($outputDirectories.Count - 1)) {
        $output = $outputDirectories[$outputIndex]
        $selectExpression = ($output.FrameNumbers | ForEach-Object { 'eq(n\,{0})' -f $_ }) -join '+'
        $filter = '[0:v:0]select={0},split=2[tiffsrc][pngsrc];[tiffsrc]format=pix_fmts=rgb48le[tiff];[pngsrc]format=pix_fmts=rgb48be[png]' -f $selectExpression
        $stagingDirectory = Join-Path $exportTempDirectory ('video_{0}' -f ($outputIndex + 1))
        $stagingTiffDirectory = Join-Path $stagingDirectory 'tiff'
        $stagingPngDirectory = Join-Path $stagingDirectory 'png'
        $tiffPattern = Join-Path $stagingTiffDirectory 'frame_%08d.tiff'
        $pngPattern = Join-Path $stagingPngDirectory 'frame_%08d.png'

        Write-Host ('Exporting {0} selected frames from {1} in one FFmpeg pass (offset {2})...' -f $output.FrameNumbers.Count, $output.Video.Name, $output.FrameOffset) -ForegroundColor Cyan
        & $ffmpegPath @(
            '-hide_banner', '-loglevel', 'error', '-nostats', '-y',
            '-i', $output.Video.FullName,
            '-filter_complex', $filter,
            '-map', '[tiff]',
            '-fps_mode', 'passthrough',
            '-c:v', 'tiff',
            '-pix_fmt', 'rgb48le',
            '-compression_algo', 'lzw',
            '-f', 'image2',
            '-start_number', '0',
            $tiffPattern,
            '-map', '[png]',
            '-fps_mode', 'passthrough',
            '-c:v', 'png',
            '-pix_fmt', 'rgb48be',
            '-compression_level', '6',
            '-f', 'image2',
            '-start_number', '0',
            $pngPattern
        )
        if ($LASTEXITCODE -ne 0) {
            throw "FFmpeg failed for '$($output.Video.FullName)' (exit code $LASTEXITCODE)."
        }

        foreach ($pendingExport in @($pendingExports | Where-Object { $_.VideoIndex -eq $outputIndex })) {
            if (-not (Test-Path -LiteralPath $pendingExport.TiffSource -PathType Leaf) -or (Get-Item -LiteralPath $pendingExport.TiffSource).Length -eq 0) {
                throw "No TIFF was produced for frame $($pendingExport.Frame) in '$($output.Video.FullName)'. Check that the selected frame exists."
            }
            if (-not (Test-Path -LiteralPath $pendingExport.PngSource -PathType Leaf) -or (Get-Item -LiteralPath $pendingExport.PngSource).Length -eq 0) {
                throw "No PNG was produced for frame $($pendingExport.Frame) in '$($output.Video.FullName)'. Check that the selected frame exists."
            }
        }
    }

    foreach ($pendingExport in $pendingExports) {
        Move-Item -LiteralPath $pendingExport.TiffSource -Destination $pendingExport.TiffDestination -Force
        Move-Item -LiteralPath $pendingExport.PngSource -Destination $pendingExport.PngDestination -Force
    }

    Write-Host ''
    Write-Host "Export complete. Images are in: $outputPath" -ForegroundColor Green
    Write-Host 'Each source video has separate folders ending in .tiff and .png.'
    $exportsCompleted = $true

    if (Read-YesNo 'Upload the TIFF images to slow.pics? (y/n)') {
        $collectionName = Read-RequiredString 'Enter the slow.pics comparison title'
        $videoTitles = @()
        foreach ($output in $outputDirectories) {
            $defaultTitle = $output.Video.BaseName
            $columnTitle = (Read-Host "Title for $($output.Video.Name) (press Enter for $defaultTitle)").Trim()
            if ([string]::IsNullOrWhiteSpace($columnTitle)) {
                $columnTitle = $defaultTitle
            }
            $videoTitles += $columnTitle
        }

        Write-Host ''
        Write-Host 'Opening slow.pics in a private browser and uploading through its visible form...' -ForegroundColor Cyan
        try {
            $comparisonUrl = Start-SlowPicsBrowserUiUpload `
                -CollectionName $collectionName `
                -VideoTitles ([string[]]$videoTitles) `
                -OutputPath $outputPath `
                -Frames ([int[]]$frames) `
                -PendingExports @($pendingExports)
        }
        catch {
            throw "slow.pics browser upload could not be completed. Exported images remain in '$outputPath'. $($_.Exception.Message)"
        }

        Write-Host ''
        Write-Host "slow.pics comparison uploaded: $comparisonUrl" -ForegroundColor Green
        Write-Host 'Share this link to let others view the comparison.'
    }
}
catch {
    Write-Host ''
    $failureMessage = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = $_.ToString()
    }
    if ([string]::IsNullOrWhiteSpace($failureMessage)) {
        $failureMessage = 'An unexpected error occurred. Check the PowerShell error details.'
    }
    $failureLabel = if ($exportsCompleted) { 'FrameKurabe failed' } else { 'Export failed' }
    Write-Host "${failureLabel}: $failureMessage" -ForegroundColor Red
    exit 1
}
finally {
    if (Test-Path -LiteralPath $exportTempDirectory -PathType Container) {
        Remove-Item -LiteralPath $exportTempDirectory -Recurse -Force
    }
}
