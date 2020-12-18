if ($args[1] -eq 'prerelease') {
  $vswhere_with_prerelease = $true
}

$path = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
if (!$path) { $path = "${env:ProgramFiles}\Microsoft Visual Studio\Installer" }
if ($path) {
  $env:Path += ";$path"

  $vswhere_req = '-requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
  $vswhere_prp = '-property installationPath'
  $vswhere_lmt = "-version `"$($args[0])`""
  [void] { & "$path\vswhere" -prerelease }
  if ($LASTEXITCODE -ne 1 -and $vswhere_with_prerelease -eq 1) {
    $vswhere_lmt += " -prerelease"
  }
  $vswhere_args = "-latest -products `* $vswhere_req $vswhere_prp $vswhere_lmt"
  $res = & $path\vswhere $vswhere_args.split(' ')
  $vcinstalldir = "$res\VC"
  $vs150comntools = "$res\Common7\Tools"
}
Else {
  exit 1
}