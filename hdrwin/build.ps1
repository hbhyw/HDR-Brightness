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

# link has to happen before javac now: the code references R.style.* for the themes,
# and R.java is what link generates.
Write-Host '[2/6] aapt2 link (also emits R.java)'
& "$bt\aapt2.exe" link -o "$out\unsigned.apk" -I $plat --manifest $manifest `
    --min-sdk-version 34 --target-sdk-version 36 `
    --version-code 2 --version-name 1.1.0 `
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

function Repair-ZipEntryNames {
    param([string]$Path)
    $tmp = "$Path.fixed"
    $src = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Read)
    $dst = [System.IO.Compression.ZipFile]::Open($tmp, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($e in $src.Entries) {
            $name = $e.FullName -replace '\\', '/'
            $ne = $dst.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
            $es = $e.Open(); $ns = $ne.Open()
            try { $es.CopyTo($ns) } finally { $ns.Dispose(); $es.Dispose() }
        }
    } finally { $src.Dispose(); $dst.Dispose() }
    Move-Item -Force $tmp $Path
}
Repair-ZipEntryNames -Path "$out\unsigned.apk"

$zip = [System.IO.Compression.ZipFile]::Open("$out\unsigned.apk",
    [System.IO.Compression.ZipArchiveMode]::Update)
try {
    $i = 0
    foreach ($dex in (Get-ChildItem -Path "$out\dex" -Filter *.dex)) {
        $entryName = if ($i -eq 0) { 'classes.dex' } else { "classes$($i + 1).dex" }
        $existing = $zip.GetEntry($entryName)
        if ($existing) { $existing.Delete() }
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $dex.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        Write-Host ("      + {0}" -f $entryName)
        $i++
    }
} finally { $zip.Dispose() }

& "$bt\zipalign.exe" -f -p 4 "$out\unsigned.apk" "$out\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'zipalign failed' }
$apk = Join-Path $work 'HDR-Brightness.apk'
& "$bt\apksigner.bat" sign --ks $ks --ks-pass pass:android --key-pass pass:android `
    --out $apk "$out\aligned.apk"
if ($LASTEXITCODE -ne 0) { throw 'apksigner failed' }

$finalApk = Join-Path $root 'HDR-Brightness.apk'
Copy-Item -Force $apk $finalApk
Copy-Item -Force $ks (Join-Path $root 'debug.keystore')

& "$bt\apksigner.bat" verify --print-certs $finalApk | Select-Object -First 3
Write-Host ''
Write-Host ("built: {0} ({1} bytes)" -f $finalApk, (Get-Item $finalApk).Length)
