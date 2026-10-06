# Build the HDR overlay app by hand (no Gradle).  ASCII-only on purpose:
# PowerShell 5 reads .ps1 as ANSI, and aapt2 chokes on non-ASCII paths.
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$sdk     = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { 'C:\tools\android-sdk' }
$bt      = Join-Path $sdk 'build-tools\36.0.0'
$plat    = Join-Path $sdk 'platforms\android-36\android.jar'
$javaBin = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin' } else { 'C:\tools\jdk17\jdk-17.0.20+8\bin' }
$javac   = Join-Path $javaBin 'javac.exe'
$keytool = Join-Path $javaBin 'keytool.exe'

$verCode = 4
$verName = '1.1.2'

foreach ($p in @($bt, $plat, $javac)) {
    if (-not (Test-Path $p)) { throw "missing: $p" }
}

$work = Join-Path $env:TEMP 'hdrwin-build'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null

Copy-Item -Recurse -Force (Join-Path $root 'app') (Join-Path $work 'app')
if (Test-Path (Join-Path $root 'debug.keystore')) {
    Copy-Item -Force (Join-Path $root 'debug.keystore') (Join-Path $work 'debug.keystore')
}
Write-Host ("work dir: {0}" -f $work)

$res      = Join-Path $work 'app\res'
$manifest = Join-Path $work 'app\AndroidManifest.xml'
$out      = Join-Path $work 'build'
$ks       = Join-Path $work 'debug.keystore'
New-Item -ItemType Directory -Force -Path "$out\classes", "$out\dex", "$out\gen" | Out-Null

Write-Host '[1/6] aapt2 compile resources'
& "$bt\aapt2.exe" compile --dir $res -o "$out\res.zip"
if ($LASTEXITCODE -ne 0) { throw 'aapt2 compile failed' }

# link has to happen before javac: the code references R.style.* for the themes,
# and R.java is what link generates.
Write-Host '[2/6] aapt2 link (also emits R.java)'
& "$bt\aapt2.exe" link -o "$out\linked.apk" -I $plat --manifest $manifest `
    --min-sdk-version 34 --target-sdk-version 36 `
    --version-code $verCode --version-name $verName `
    --java "$out\gen" "$out\res.zip"
if ($LASTEXITCODE -ne 0) { throw 'aapt2 link failed' }

Write-Host '[3/6] javac'
$srcFiles = @(Get-ChildItem -Path (Join-Path $work 'app\src') -Recurse -Filter *.java |
    ForEach-Object { $_.FullName })
$srcFiles += @(Get-ChildItem -Path "$out\gen" -Recurse -Filter *.java |
    ForEach-Object { $_.FullName })
Write-Host ("      sources={0} (app + generated R.java)" -f $srcFiles.Count)
& $javac -encoding UTF-8 -source 11 -target 11 -nowarn -classpath $plat -d "$out\classes" @srcFiles
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }

Write-Host '[4/6] d8 to dex'
$classFiles = @(Get-ChildItem -Path "$out\classes" -Recurse -Filter *.class | ForEach-Object { $_.FullName })
& "$bt\d8.bat" --release --min-api 34 --lib $plat --output "$out\dex" @classFiles
if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }

if (-not (Test-Path $ks)) {
    Write-Host '[5/6] create debug keystore'
    & $keytool -genkeypair -keystore $ks -storepass android -keypass android `
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 `
        -dname 'CN=Android Debug,O=Android,C=US'
    if ($LASTEXITCODE -ne 0) { throw 'keytool failed' }
} else {
    Write-Host '[5/6] reuse debug keystore'
}

Write-Host '[6/6] inject classes.dex + zipalign + sign'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Take aapt2's APK and only ADD classes.dex -- leave every existing entry byte-for-byte
# alone.
#
# DO NOT "normalise" the zip by copying every entry through CreateEntry().  aapt2 stores
# resources.arsc uncompressed and 4-byte aligned on purpose, and a deflated resources.arsc
# is rejected at install time on targetSdk >= 30 with
# INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED (-124):
#   "Targeting R+ (version 30 and above) requires the resources.arsc of installed APKs
#    to be stored uncompressed and aligned on a 4-byte boundary"
# Worse, asking .NET for NoCompression does not help: under Windows PowerShell's
# .NET Framework, CreateEntry(name, CompressionLevel.NoCompression) still emits DEFLATE.
# ZipArchiveMode.Update does the right thing -- entries it never opens are copied
# verbatim, method and all.
$packed = "$out\packed.apk"
Copy-Item -Force "$out\linked.apk" $packed
$zip = [System.IO.Compression.ZipFile]::Open($packed, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    $i = 0
    foreach ($dex in (Get-ChildItem -Path "$out\dex" -Filter *.dex | Sort-Object Name)) {
        $entryName = if ($i -eq 0) { 'classes.dex' } else { "classes$($i + 1).dex" }
        $existing = $zip.GetEntry($entryName)
        if ($existing) { $existing.Delete() }
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $dex.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        Write-Host ("      + {0}" -f $entryName)
        $i++
    }
} finally { $zip.Dispose() }

& "$bt\zipalign.exe" -f -p 4 $packed "$out\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'zipalign failed' }
$apk = Join-Path $work 'HDR-Brightness.apk'
& "$bt\apksigner.bat" sign --ks $ks --ks-pass pass:android --key-pass pass:android `
    --out $apk "$out\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'apksigner failed' }

$finalApk = Join-Path $root 'HDR-Brightness.apk'
Copy-Item -Force $apk $finalApk
Copy-Item -Force $ks (Join-Path $root 'debug.keystore')

# ------------------------------------------------------------------ sanity check
# Read the zip back the same way PackageManagerService does, and refuse to ship a
# broken APK.  This is exactly the check that produced -124 in the first place.
function Assert-ArscInstallable {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    $eocd = -1
    for ($i = $b.Length - 22; $i -ge 0 -and $i -ge $b.Length - 22 - 65535; $i--) {
        if ($b[$i] -eq 0x50 -and $b[$i + 1] -eq 0x4B -and
            $b[$i + 2] -eq 0x05 -and $b[$i + 3] -eq 0x06) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw 'not a zip file' }
    $total = [BitConverter]::ToUInt16($b, $eocd + 10)
    $p = [int][BitConverter]::ToUInt32($b, $eocd + 16)
    for ($n = 0; $n -lt $total; $n++) {
        $method  = [BitConverter]::ToUInt16($b, $p + 10)
        $nameLen = [BitConverter]::ToUInt16($b, $p + 28)
        $extra   = [BitConverter]::ToUInt16($b, $p + 30)
        $cmt     = [BitConverter]::ToUInt16($b, $p + 32)
        $lho     = [int][BitConverter]::ToUInt32($b, $p + 42)
        $name    = [System.Text.Encoding]::UTF8.GetString($b, $p + 46, $nameLen)
        if ($name -eq 'resources.arsc') {
            $off = $lho + 30 +
                   [BitConverter]::ToUInt16($b, $lho + 26) +
                   [BitConverter]::ToUInt16($b, $lho + 28)
            if ($method -ne 0) {
                throw "resources.arsc is compressed (method=$method) -> install fails with -124"
            }
            if (($off % 4) -ne 0) {
                throw "resources.arsc not 4-byte aligned (data offset $off) -> install fails with -124"
            }
            Write-Host ("      resources.arsc: STORED, data offset {0} (4-byte aligned)" -f $off)
            return
        }
        $p += 46 + $nameLen + $extra + $cmt
    }
    throw 'resources.arsc not found in the APK'
}
Write-Host 'checking resources.arsc is installable...'
Assert-ArscInstallable -Path $finalApk

& "$bt\zipalign.exe" -c -v 4 $finalApk 2>&1 | Select-Object -Last 1
& "$bt\apksigner.bat" verify --print-certs $finalApk | Select-Object -First 3
Write-Host ''
Write-Host ("built: {0} ({1} bytes)" -f $finalApk, (Get-Item $finalApk).Length)
