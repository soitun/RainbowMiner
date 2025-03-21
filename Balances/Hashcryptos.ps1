using module ..\Modules\Include.psm1

param(
    [String]$Name,
    $Config
)

# $Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

$Request = [PSCustomObject]@{}

$Payout_Currencies = $Config.Pools.$Name.Wallets.PSObject.Properties | Where-Object {$_.Value -and @("BCH","BSV","BTC","DASH","DGB","DOGE","FTC","GRS","LTC","MONA","PEPEW","RVN","VTC","XEC","XMR","XMY","XVG","ZEC") -icontains $_.Name} | Select-Object Name,Value -Unique | Sort-Object Name,Value

if (-not $Payout_Currencies) {
    Write-Log -Level Verbose "Cannot get balance on pool ($Name) - no wallet address specified. "
    return
}

$headers = @{"Accept"="text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8"}

$Count = 0
$Payout_Currencies | Where-Object {-not $Config.ExcludeCoinsymbolBalances.Count -or $Config.ExcludeCoinsymbolBalances -notcontains "$($_.Name)"} | Foreach-Object {
    try {
        $Request = Invoke-RestMethodAsync "https://www.hashcryptos.com/api/walletEx?address=$($_.Value)" -headers $headers -delay $(if ($Count){1000} else {0}) -cycletime ($Config.BalanceUpdateMinutes*60)
        $Count++
        if (($Request | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Measure-Object Name).Count -le 1) {
            Write-Log -Level Info "Pool Balance API ($Name) for $($_.Name) returned nothing. "
        } else {
            [PSCustomObject]@{
                Caption     = "$($Name) ($($Request.symbol))"
				BaseName    = $Name
                Name        = $Name
                Currency    = $Request.symbol
                Balance     = [Decimal]$Request.balance
                Pending     = [Decimal]$Request.unsold
                Total       = [Decimal]$Request.balance + [Decimal]$Request.unsold
                Paid        = [Decimal]$Request.total - [Decimal]$Request.unpaid
                Paid24h     = [Decimal]$Request.paid24h
                Earned      = [Decimal]$Request.total
                Payouts     = @(Get-BalancesPayouts $Request.payouts | Select-Object)
                LastUpdated = (Get-Date).ToUniversalTime()
            }
        }
    }
    catch {
        Write-Log -Level Verbose "Pool Balance API ($Name) for $($_.Name) has failed. "
    }
}
