<#
.SYNOPSIS
  從原始碼建置 justwatchcom/sql_exporter 的 Windows 版 sql_exporter.exe。

.DESCRIPTION
  上游沒有發佈任何二進位檔，只有 Docker image。此腳本：
    1. 下載一份獨立的 Go 工具鏈到 temp（不影響機器上已裝的 Go）
    2. clone 指定 tag 的原始碼（開 core.longpaths，vendor 內有超長路徑）
    3. go build 成靜態的 sql_exporter.exe 放到本腳本所在資料夾
  實測：go1.27.1 + v0.8，產出約 60 MB。

.PARAMETER Tag
  sql_exporter 的 git tag，預設 v0.8。

.PARAMETER GoVersion
  要下載的 Go 版本，預設抓 go.dev 公布的最新穩定版。上游 go.mod 要求 1.24 以上。
#>
param(
    [string]$Tag = "v0.8",
    [string]$GoVersion = ""
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = Join-Path $env:TEMP "sql_exporter_build"
New-Item -ItemType Directory -Force $work | Out-Null

if (-not $GoVersion) {
    $GoVersion = (Invoke-WebRequest -Uri "https://go.dev/VERSION?m=text" -UseBasicParsing).Content.Split("`n")[0].Trim()
}
$goDir = Join-Path $work $GoVersion
if (-not (Test-Path (Join-Path $goDir "go\bin\go.exe"))) {
    $zip = Join-Path $work "$GoVersion.windows-amd64.zip"
    Write-Host "Downloading $GoVersion ..."
    Invoke-WebRequest -Uri "https://go.dev/dl/$GoVersion.windows-amd64.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $goDir -Force
}
$go = Join-Path $goDir "go\bin\go.exe"
& $go version

$src = Join-Path $work "src_$Tag"
if (-not (Test-Path (Join-Path $src "go.mod"))) {
    Write-Host "Cloning sql_exporter $Tag ..."
    git -c core.longpaths=true clone --quiet --depth 1 --branch $Tag https://github.com/justwatchcom/sql_exporter.git $src
}

$env:GOFLAGS = "-mod=vendor"
$env:GOTOOLCHAIN = "local"
$env:CGO_ENABLED = "0"
$out = Join-Path $here "sql_exporter.exe"
Push-Location $src
try {
    & $go build -ldflags="-s -w" -o $out .
} finally {
    Pop-Location
}

Write-Host "Built: $out"
& $out -version
