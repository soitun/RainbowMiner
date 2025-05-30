﻿Function Start-APIServer {

    # Create a global synchronized hashtable that all threads can access to pass data between the main script and API
    $Global:API = [System.Collections.Hashtable]::Synchronized(@{})

    # Initialize firewall and prefix
    if ($Session.IsAdmin -and $Session.Config.APIport) {Initialize-APIServer -Port $Session.Config.APIport}
  
    # Setup flags for controlling script execution
    $API.Stop        = $false
    $API.Pause       = $false
    $API.Update      = $false
    $API.Reboot      = $false
    $API.UpdateBalance = $false
    $API.UpdateMRR   = $false
    $API.WatchdogReset = $false
    $API.ApplyOC     = $false
    $API.LockMiners  = $false
    $API.IsVirtual   = $false
    $API.CmdMenu     = @()
    $API.CmdKey      = ''
    $API.APIport     = $Session.Config.APIport
    $API.RandTag     = Get-MD5Hash("$((Get-Date).ToUniversalTime())$(Get-Random)")
    $API.RemoteAPI   = Test-APIServer -Port $Session.Config.APIport
    $API.IsServer    = $Session.Config.RunMode -eq "Server"
    $API.MachineName = $Session.MachineName
    $API.Debug       = $Session.LogLevel -eq "Debug"
    $API.PauseMiners = [PSCustomObject]@{Pause = $false;PauseIA = $false;PauseIAOnly = $false}

    Set-APIConfig
    Set-APICredentials

    # Setup the global HTTP listener
    $Global:APIHttpListener = New-Object System.Net.HttpListener
    if ($API.RemoteAPI) {
        [void]$Global:APIHttpListener.Prefixes.Add("http://+:$($API.APIport)/")
        # Require authentication when listening remotely
        $Global:APIHttpListener.AuthenticationSchemes = if ($API.APIauth) {[System.Net.AuthenticationSchemes]::Basic} else {[System.Net.AuthenticationSchemes]::Anonymous}
    } else {
        [void]$Global:APIHttpListener.Prefixes.Add("http://localhost:$($API.APIport)/")
    }
    $Global:APIHttpListener.Start()

    # Setup additional, global variables for server handling
    $Global:APIClients   = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $Global:APIListeners = [System.Collections.ArrayList]@()
    $Global:APIAccessDB  = [System.Collections.Hashtable]::Synchronized(@{})
    $Global:APICacheDB   = [System.Collections.Hashtable]::Synchronized(@{})

    # Setup runspacepool to launch the API webserver in separate threads
    $initialSessionState = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('API', $API, $null))
    [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('Rates', $Global:Rates, $null))
    [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('StatsCache', $Global:StatsCache, $null))
    [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('Session', $Session, $null))
    [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('AsyncLoader', $AsyncLoader, $null))
    [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('APIClients', $APIClients, $null))
    [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('APIAccessDB', $APIAccessDB, $null))
    [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('APICacheDB', $APICacheDB, $null))
    if (Initialize-HttpClient) {
        [void]$initialSessionState.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new("GlobalHttpClient", $Global:GlobalHttpClient, $null))
    }

    foreach ($Module in @("APILib","ConfigLib","Include","MiningRigRentals","StatLib","TcpLib","WebLib","WhatToMineLib")) {
        [void]$initialSessionState.ImportPSModule((Resolve-Path ".\Modules\$($Module).psm1"))
    }

    $MinThreads = 1
    $MaxThreads = if ($Session.Config.APIthreads) {$Session.Config.APIthreads} elseif ($API.IsServer) {$MinThreads = 2;[Math]::Min($Global:GlobalCPUInfo.Threads,8)} else {[Math]::Min($Global:GlobalCPUInfo.Cores,2)}
    $MaxThreads = [Math]::Max($MinThreads,$MaxThreads)

    $Global:APIRunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $initialSessionState, $Host)
    $Global:APIRunspacePool.Open()

    $APIScript = [ScriptBlock]::Create((Get-Content ".\Scripts\API.ps1" -Raw))

    for($ThreadID = 0; $ThreadID -lt $MaxThreads; $ThreadID++) {
        $newPS = [PowerShell]::Create().AddScript($APIScript).AddParameters(@{'ThreadID'=$ThreadID;'APIHttpListener'=$Global:APIHttpListener;'CurrentPwd'=$PWD})
        $newPS.RunspacePool = $Global:APIRunspacePool

        [void]$Global:APIListeners.Add([PSCustomObject]@{
            Runspace   = $newPS.BeginInvoke()
		    PowerShell = $newPS 
        })
    }
    Write-Log -Level Info "Started $($MaxThreads) API threads on port $($API.APIport)"
}

Function Stop-APIServer {
    if (-not (Test-Path Variable:Global:API)) {return}
    $Global:API.Stop = $true

    if ($Global:APIListeners) {
        foreach ($Listener in $Global:APIListeners.ToArray()) {
			$Listener.PowerShell.Dispose()
			[void]$Global:APIListeners.Remove($Listener)
		}
    }
    $Global:APIListeners.Clear()

    $Global:APIRunspacePool.Close()

    $Global:APIHttpListener.Stop()
    $Global:APIHttpListener.Close()

    $Global:APIListeners = $null
    $Global:APIRunspacePool = $null
    $Global:APIHttpListener = $null

    $Global:API = $null
    Remove-Variable -Name API -Scope Global -Force -ErrorAction Ignore
}

function Set-APIConfig {
    $API.LockConfig  = $Session.Config.APIlockConfig
    $API.MaxLoginAttempts = $Session.Config.APImaxLoginAttemps
    $API.BlockLoginAttemptsTime = ConvertFrom-Time $Session.Config.APIblockLoginAttemptsTime
    $API.AllowIPs    = $Session.Config.APIallowIPs
}

function Set-APICredentials {
    $API.APIauth     = $Session.Config.APIauth -and $Session.Config.APIuser -and $Session.Config.APIpassword
    $API.APIuser     = $Session.Config.APIuser
    $API.APIpassword = $Session.Config.APIpassword
}

function Get-APIServerName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Int]$Port,
        [Parameter(Mandatory = $false)]
        [String]$Protocol = "TCP"
    )
    "RainbowMiner API $($Port)$(if ($Protocol -ne "TCP") {" $Protocol"})"
}

function Send-APIServerUdp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Int]$Port,
        [Parameter(Mandatory = $false)]
        [String]$MachineName = [System.Environment]::MachineName,
        [Parameter(Mandatory = $false)]
        [String]$IPaddress = ""
    )
    
    try {
        $UdpClient   = new-Object system.Net.Sockets.Udpclient 
        if ($UdpClient) {
            $Buffer = "RBM:$($MachineName):$(if ($IPaddress) {$IPaddress} else {Get-MyIP}):$($Port)"
            $byteBuffer = [System.Text.Encoding]::ASCII.GetBytes($Buffer)
            $UdpClient.Send($byteBuffer, $byteBuffer.length, [system.net.IPAddress]::Broadcast, $Port)
        }
        $true
    } catch {}
}

function Test-APIServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Int]$Port,
        [Parameter(Mandatory = $false)]
        [string]$Type = "all"
    )
    $rv = $true
    if ($IsWindows) {
        if ($rv -and ($Type -eq "firewall" -or $Type -eq "firewall-tcp" -or $Type -eq "all")) {
            $FWLname = Get-APIServerName -Port $Port -Protocol "TCP"
            $fwlACLs = & netsh advfirewall firewall show rule name="$($FWLname)" | Out-String
            if (-not $fwlACLs.Contains($FWLname)) {$rv = $false}
        }
        if ($rv -and ($Type -eq "firewall" -or $Type -eq "firewall-udp" -or $Type -eq "all")) {
            $FWLname = Get-APIServerName -Port $Port -Protocol "UDP"
            $fwlACLs = & netsh advfirewall firewall show rule name="$($FWLname)" | Out-String
            if (-not $fwlACLs.Contains($FWLname)) {$rv = $false}
        }
        if ($rv -and ($Type -eq "url" -or $Type -eq "all")) {
            $urlACLs = & netsh http show urlacl | Out-String
            if (-not $urlACLs.Contains("http://+:$($Port)/")) {$rv = $false}
        }
    }
    $rv
}

function Initialize-APIServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Int]$Port
    )

    if ($IsWindows) {
        if (-not (Test-APIServer -Port $Port -Type "url")) {
            # S-1-5-32-545 is the well known SID for the Users group. Use the SID because the name Users is localized for different languages
            (Start-Process netsh -Verb runas -PassThru -ArgumentList "http add urlacl url=http://+:$($Port)/ sddl=D:(A;;GX;;;S-1-5-32-545) user=everyone").WaitForExit(5000)>$null
        }

        if (-not (Test-APIServer -Port $Port -Type "firewall-tcp")) {
            (Start-Process netsh -Verb runas -PassThru -ArgumentList "advfirewall firewall add rule name=`"$(Get-APIServerName -Port $Port -Protocol "TCP")`" dir=in action=allow protocol=TCP localport=$($Port)").WaitForExit(5000)>$null
        }

        if (-not (Test-APIServer -Port $Port -Type "firewall-udp")) {
            (Start-Process netsh -Verb runas -PassThru -ArgumentList "advfirewall firewall add rule name=`"$(Get-APIServerName -Port $Port -Protocol "UDP")`" dir=in action=allow protocol=UDP localport=$($Port)").WaitForExit(5000)>$null
        }
    }
}

function Reset-APIServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Int]$Port
    )

    if ($IsWindows) {
        if (Test-APIServer -Port $Port -Type "url") {
            (Start-Process netsh -Verb runas -PassThru -ArgumentList "http delete urlacl url=http://+:$($Port)/").WaitForExit(5000)>$null
        }

        if (Test-APIServer -Port $Port -Type "firewall")  {
            (Start-Process netsh -Verb runas -PassThru -ArgumentList "advfirewall firewall delete rule name=`"$(Get-APIServerName -Port $Port -Protocol "TCP")`"").WaitForExit(5000)>$null
            (Start-Process netsh -Verb runas -PassThru -ArgumentList "advfirewall firewall delete rule name=`"$(Get-APIServerName -Port $Port -Protocol "UDP")`"").WaitForExit(5000)>$null
        }
    }
}
