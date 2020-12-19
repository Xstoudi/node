$DebugPreference = "SilentlyContinue"

Set-Location $PSScriptRoot

#region Vars

# ???
$js_suites = 'default'
$native_suites = 'addons js-native-api node-api'

# CI_* variable should be kept synchronized with the ones in Makefile
$CI_NATIVE_SUITES = "$native_suites benchmark"
$CI_JS_SUITES = $js_suites
$CI_DOC = 'doctool'

# Same as test-ci target in Makefile
# TODO : set des variables cheloues
$common_test_suites = "$js_suites $native_suites"


# General
$config = 'Release'
$target = 'Build'
$target_name = ''
$target_arch = 'x64'
$node_version = $null
$tag = $null
$fullversion = $null

# Args arrays
$configure_args = New-Object System.Collections.ArrayList
$test_args = New-Object System.Collections.ArrayList
$msi_args = New-Object System.Collections.ArrayList
$node_gyp_exe = New-Object System.Collections.ArrayList
$cctest_args = New-Object System.Collections.ArrayList
$extra_msbuild_args = New-Object System.Collections.ArrayList

# Flags (meh)
$cctest = $false
$no_cctest = $false
$target_env = 
$noprojgen = $false
$projgen = $false
$nobuild = $false
$sign = $false
$licensertf = $false
$lint_cpp = $false
$lint_js = $false
$lint_js_ci = $false
$lint_md = $false
$lint_md_build = $false
$build_addons = $false
$openssl_no_asm = $false
$doc = $false
$build_js_native_api_tests = $false
$build_node_api_tests = $false
$package = $false
$msi = $false
$upload = $false
$i18n_arg = ''

$test_node_inspect = $false
$test_check_deopts = $false
$test_npm = $false
$test_v8 = $false
$test_v8_intl = $false
$test_v8_benchmarks = $false
$custom_v8_test = $false
$disttypedir = $null
#endregion Vars 


#region Functions
function ExitWithCode () {
  param (
    $exit_code
  )
  exit $(if ($LASTEXITCODE -ne 0) { $LASTEXITCODE } Else { $exit_code })
}

function RunCmdAndSetEnv () {
  param (
    $command
  )
  cmd /c "$command && set" |
  ForEach-Object {
    if ($_ -match "=") {
      $v = $_.split("="); Set-Item -Force -Path "Env:\$($v[0])"  -Value "$($v[1])"
    }
    else {
      Write-Output $_
    }
  }
}

function Get-NodeVersion () {
  $node_version = python "tools\getnodeversion.py"
  if (!$node_version) {
    Write-Error 'Cannot determine current version of Node.js.'
    ExitWithCode(1)
  }
  if (!$env:DISTTYPE) {
    $env:DISTTYPE = 'release'
  }
  if ($env:DISTTYPE -eq 'release') {
    $fullversion = $node_version
    if (!$disttypedir) {
      $disttypedir = $env:DISTTYPE
    }
    $target_name = "node-v$fullversion-win-$target_arch"
  }
  Elseif ($env:DISTTYPE -eq 'custom') {
    if (!$env:CUSTOMTAG) {
      Write-Error 'CUSTOMTAG is not set for DISTTYPE=custom'
      ExitWithCode(1)
    }
    $tag = $env:CUSTOMTAG
  }
  Else {
    if (!$env:DATESTRING) {
      Write-Error 'DATESTRING is not set for nightly'
      ExitWithCode(1)
    }
    if (!$env:COMMIT) {
      Write-Error 'COMMIT is not set for nightly'
      ExitWithCode(1)
    }
    if ($env:DISTTYPE -ne 'nightly') {
      if ($env:DISTTYPE -ne 'next-nightly') {
        Write-Error 'DISTTYPE is not release, custom, nightly or next-nightly'
        ExitWithCode(1)
      }
    }
    $tag = "$env:DISTTYPE$env:DATESTRING$env:COMMIT"
  }
  $fullversion = "$node_version-$tag"
}

function MSBuildNotFound () {
  Write-Output 'Failed to find a suitable Visual Studio installation.'
  Write-Output 'Try to run in a "Developer Command Prompt" or consult'
  Write-Output 'https://github.com/nodejs/node/blob/master/BUILDING.md#windows'
  ExitWithCode(1)
}

function SkipConfigure () {
  Write-Output 'SKIP CONFIGURE'
  Remove-Item .tmp_gyp_configure_stamp
  Write-Output "Reusing solution generated with $configure_args"
}

function RunConfigure () {
  Remove-Item .tmp_gyp_configure_stamp -Force
  Remove-Item .gyp_configure_stamp -Force -ErrorAction SilentlyContinue
  # Generate the VS project.
  Write-Output "configure $configure_args"
  $configure_args > .used_configure_flags
  . python configure $configure_args
  if ($LASTEXITCODE -eq 1 -or !(Test-Path node.sln)) {
    Write-Output 'Failed to create vc project files.'
    Remove-Item .used_configure_flags
    ExitWithCode(1)
  }
  $project_generated = $true
  Write-Output 'Project files generated.'
  $configure_args > .gyp_configure_stamp
  where.exe /R . /T *.gyp? >> .tmp_gyp_configure_stamp
}

function Build() {
  # Skip build if requested
  if ($nobuild -eq $true) {
    return
  }

  # Build the sln with msbuild
  $msbcpu = '/m:2'
  if ($env:NUMBER_OF_PROCESSORS -eq '1') {
    $msbcpu = '/m:1'
  }
  $msbplatform = 'Win32'
  if ($target_arch -eq 'x64') {
    $msbplatform = 'x64'
  }
  if ($target_arch -eq 'arm64') {
    $msbplatform = 'ARM64'
  }
  if ($target -eq 'Build') {
    if ($no_cctest -eq $true) {
      $target = 'node'
    }
    if ($test_args.Count -eq 0) {
      $target = 'node'
    }
    if ($cctest -eq $true) {
      $target = 'Build'
    }
  }
  if ($target -eq 'node' -and (Test-Path "$config\cctest.exe")) {
    Remove-Item "$config\cctest.exe"
  }
  if ($Env:msbuild_args) {
    [void] ($extra_msbuild_args.Add($Env:msbuild_args))
  }

  # Setup en variables to use multiprocessor build
  $env:UseMultiToolTask = 'True'
  $env:EnforceProcessCountAcrossBuilds = 'True'
  $env:MultiProcMaxCount = $env:NUMBER_OF_PROCESSORS
  msbuild node.sln $msbcpu /t:$target /p:Configuration=$config /p:Platform=$msbplatform "/clp:NoItemAndPropertyList;Verbosity=minimal" /nologo $extra_msbuild_args
  if ($project_generated -eq $false) {
    Write-Output 'Building Node with reused solution failed. To regenerate project files use "vcbuild projgen"'
  }
}
#endregion Functions

#region Help
if ($args[0] -eq 'help') {
  Write-Output @"
vcbuild.ps1 [debug/release] [msi] [doc] [test/test-all/test-addons/test-js-native-api/test-node-api/test-benchmark/test-internet/test-pummel/test-simple/test-message/test-tick-processor/test-known-issues/test-node-inspect/test-check-deopts/test-npm/test-async-hooks/test-v8/test-v8-intl/test-v8-benchmarks/test-v8-all] [ignore-flaky] [static/dll] [noprojgen] [projgen] [small-icu/full-icu/without-intl] [nobuild] [nosnapshot] [noetw] [ltcg] [licensetf] [sign] [ia32/x86/x64/arm64] [vs2017] [download-all] [enable-vtune] [lint/lint-ci/lint-js/lint-js-ci/lint-md] [lint-md-build] [package] [build-release] [upload] [no-NODE-OPTIONS] [link-module path-to-module] [debug-http2] [debug-nghttp2] [clean] [cctest] [no-cctest] [openssl-no-asm]
Examples:
  vcbuild.ps1                          : builds release build
  vcbuild.ps1 debug                    : builds debug build
  vcbuild.ps1 release msi              : builds release build and MSI installer package
  vcbuild.ps1 test                     : builds debug build and runs tests
  vcbuild.ps1 build-release            : builds the release distribution as used by nodejs.org
  vcbuild.ps1 enable-vtune             : builds nodejs with Intel VTune profiling support to profile JavaScript
  vcbuild.ps1 link-module my_module.js : bundles my_module as built-in module
  vcbuild.ps1 lint                     : runs the C++, documentation and JavaScript linter
  vcbuild.ps1 no-cctest                : skip building cctest.exe
"@
  exit
}
#endregion Help

#region Load arguments
switch ($args) {
  'debug' { 
    $config = 'Debug'
  }
  'release' {
    $config = 'Release'
    [void] ($configure_args.Add('--with-ltcg'))
    $cctest = $true
  }
  'clean' {
    $target = 'Clean' 
  }
  'testclean' {
    $target = 'TestClean' 
  }
  'ia32' {
    $target_arch = 'x86' 
  }
  'x86' {
    $target_arch = 'x86' 
  }
  'x64' {
    $target_arch = 'x64' 
  }
  'arm64' { 
    $target_arch = 'arm64' 
  }
  'vs2019' {
    $target_env = 'vs2019'
    [void] ($node_gyp_exe.Add('--msvs_version=2019'))
  }
  'noprojgen' { 
    $noprojgen = $true 
  }
  'projgen' { 
    $projgen = $true 
  }
  'nobuild' { 
    $nobuild = $true 
  }
  # Should disappear I think
  'nosign' { 
    Write-Warning 'vcbuild no longer signs by default. "nosign" is redundant.' 
  }
  'sign' { 
    $sign = $true 
  }
  'nosnapshot' { 
    [void] ($configure_args.Add('--without-snapshot'))
  }
  'noetw' {
    [void] ($configure_args.Add('--without-etw'))
    [void] ($msi_args.Add('/p:NoETW=1'))
  }
  'ltcg' { 
    [void] ($configure_args.Add('--with-ltcg'))
  }
  'licensertf' { 
    $licensertf = $true 
  }
  'test' {
    [void] ($test_args.Add("-J $common_test_suites"))
    $lint_cpp = $true
    $lint_js = $true
    $lint_md = $true
  }
  'test-ci-native' {
    # is really test_ci_args coming from ENV?
    [void] ($test_args.Add("$env:test_ci_args -J -p tap --logfile test.tap $CI_NATIVE_SUITES $CI_DOC"))
  
    $build_addons = $true
    $build_js_native_api_tests = $true
    $build_node_api_tests = $true
    [void] ($cctest_args.Add('--gtest_output=xml:cctest.junit.xml'))
  }
  'test-ci-js' {
    [void] ($test_args.Add("-J -p tap --logfile test.tap $CI_JS_SUITES"))
    $no_cctest = $true
  }
  'build-addons' {
    $build_addons = $true 
  }
  'build-js-native-api-tests' { 
    $build_js_native_api_tests = $true 
  }
  'build-node-api-tests' { 
    $build_node_api_tests = $true 
  }
  'test-addons' { 
    [void] ($test_args.Add('addons'))
    $build_addons = $true
  }
  'test-doc' {
    [void] ($test_args.Add($CI_DOC))
    $doc = $true
    $lint_js = $true
    $lint_md = $true
  }
  'test-js-native-api' {
    [void] ($test_args.Add('js-native-api'))
    $build_js_native_api_tests = $true
  }
  'test-node-api' {
    [void] ($test_args.Add('node-api'))
    $build_node_api_tests = $true
  }
  'test-benchmark' {
    [void] ($test_args.Add('benchmark'))
  }
  'test-simple' {
    [void] ($test_args.Add('squential parallel -J'))
  }
  'test-message' {
    [void] ($test_args.Add('message'))
  }
  'test-tick-processor' {
    [void] ($test_args.Add('tick-processor'))
  }
  'test-internet' {
    [void] ($test_args.Add('internet'))
  }
  'test-pummel' {
    [void] ($test_args.Add('pummel'))
  }
  'test-known-issues' {
    [void] ($test_args.Add('known-issues'))
  }
  'test-async-hooks' {
    [void] ($test_args.Add('test-async-hooks'))
  }
  'test-all' {
    [void] ($test_args.Add("gc internet pummel $common_test_suites"))
    $lint_cpp = $true
    $lint_js = $true
  }
  'test-node-inspect' {
    $test_node_inspect = $true
  }
  'test-check-deopts' {
    $test_check_deopts = $true
  }
  'test-npm' {
    $test_npm = $true
  }
  'test-v8' {
    $test_v8 = $true
    $custom_v8_test = $true
  }
  'test-v8-intl' {
    $test_v8_benchmarks = $true
    $custom_v8_test = $true
  }
  'test-v8-all' {
    $test_v8 = $true
    $test_v8_intl = $true
    $test_v8_benchmarks = $true
    $custom_v8_test = $true
  }
  'lint-cpp' {
    $lint_cpp = $true
  }
  'lint-js' {
    $lint_js = $true
  }
  # Should disappear I think
  'jslint' {
    $lint_js = $true
    Write-Warning 'Please use "lint-js" instead of "jslint".'
  }
  'lint-md' {
    $lint_md = $true
  }
  'lint-md-build' {
    $lint_md_build = $true
  }
  'lint' {
    $lint_cpp = $true
    $lint_js = $true
    $lint_md = $true
  }
  'lint-ci' {
    $lint_cpp = $true
    $lint_js_ci = $true
  }
  'package' {
    $package = $true
  }
  'msi' {
    $msi = $true
    $licensertf = $true
    [void] ($configure_args.Add('--download=all'))
    $i18n_arg = 'full-icu'
  }
  'build-release' {
    $config = 'Release'
    $package = $true
    $msi = $true
    $licensertf = $true
    [void] ($configure_args.Add('--download=all'))
    $i18n_arg = 'full-icu'
    $projgen = $true
    $cctest = $true
    [void] ($configure_args.Add('--with-ltcg'))
    [void] ($configure_args.Add('--with-ltcg'))
  }
  'upload' {
    $upload = $true
  }
  'small-icu' {
    $i18n_arg = 'small-icu'
  }
  'full-icu' {
    $i18n_arg = 'full-icu'
  }
  'intl-none' {
    $i18n_arg = 'none'
  }
  'without-intl' {
    $i18n_arg = 'none'
  }
  'download-all' {
    [void] ($configure_args.Add('--download=all'))
  }
  'ignore-flaky' {
    [void] ($test_args.Add('--flaky-tests=dontcare'))
  }
  'dll' {
    [void] ($configure_args.Add('--shared'))
  }
  'static' {
    [void] ($configure_args.Add('--enable-static'))
  }
  'no-NODE-OPTIONS' {
    [void] ($configure_args.Add('--without-node-options'))
  }
  # Unused in the bat file
  'debug-nghttp2' {}
  'link-module' {
    $switch.MoveNext()
    $current = $switch.Current
    [void] ($configure_args.Add("--link-module $current"))
  }
  'no-cctest' {
    $no_cctest = $true
  }
  'cctest' {
    $cctest = $true
  }
  'openssl-no-asm' {
    $openssl_no_asm = $true
    [void] ($configure_args.Add('--openssl-no-asm'))
  }
  'doc' {
    $doc = $true
  }
  'binlog' {
    [void] ($extra_msbuild_args.Add("/binaryLogger:$config\node.binlog"))
  }
  'experimental-quic' {
    [void] ($configure_args.Add('--experimental-quic'))
  }
  default {
    Write-Output "Error: invalid command line option $_."
    $exit_code = 1
    ExitWithCode
  }
}
#endregion Load arguments

[void] ($configure_args.Add("--dest-cpu=$target_arch"))

if ($target_arch -eq 'x86' -and $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') {
  [void] ($configure_args.Add('--no-cross-compiling'))
}
if ($target_arch -eq 'arm64') {
  [void] ($configure_args.Add('--cross-compiling'))
}

if ($target -eq 'Clean' -and (Test-Path "deps\icu") -eq $true) {
  Write-Output "deleting $PSScriptRoot\deps\icu"
  Remove-Item -Path "deps\icu" -Recurse
}

if ($target -eq "TestClean") {
  Write-Output "deleting $PSScriptRoot\test/.tmp*"
  Remove-Item test/.tmp* -Recurse -Force
}

RunCmdAndSetEnv '.\tools\msvs\find_python.cmd'
if ($LASTEXITCODE -eq 1) {
  ExitWithCode 
}

# NASM is only needed on IA32 and x86_64
if ($openssl_no_asm -eq $false -and $target_arch -ne 'arm64') {
  RunCmdAndSetEnv '.\tools\msvs\find_nasm.cmd'
  if ($LASTEXITCODE -eq 1) {
    Write-Output 'Could not find NASM, install it or build with openssl-no-asm. See BUILDING.md.'
  }
}

Get-NodeVersion

if ($tag) {
  [void] ($configure_args.Add("--tag=$tag"))
}

if ($target -eq 'Clean') {
  # What are those files?
  Remove-Item -Recurse "config\$target_name"
}

if ($noprojgen -eq $false -or $nobuild -eq $false) {
  # Set environment for msbuild
  $msvs_host_arch = 'x86'
  if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') {
    $msvs_host_arch = 'amd64'
  }
  
  # Usually vcvarsall takes an argument: host + '_' + target
  $vcvarsall_arg = "$($msvs_host_arch)_$($target_arch)"
  # Unless both host and target are x64
  if ($target_arch -eq 'x64' -and $msvs_host_arch -eq 'amd64') {
    $vcvarsall_arg = 'amd64'
  }
  # Also if both are x86
  if ($target_arch -eq 'x86' -and $msvs_host_arch -eq 'x86') {
    $vcvarsall_arg = 'x86'
  }
  
  # Look for Visual Studio 2019
  if ($target_env -and $target_env -ne 'vs2019') {
    MSBuildNotFound
  }
  Write-Output 'Looking for Visual Studio 2019'
  # VCINSTALLDIR may be set if run from a VS Command Prompt and needs to be
  # cleared first as vswhere_usability_wrapper.cmd doesn't when it fails to
  # detect the version searched for
  if (!$target_env) {
    $vcinstalldir = ''
  }
  . .\tools\msvs\vswhere_usability_wrapper.ps1 "[16.0,17.0)" "prerelease"
  if (!$vcinstalldir) {
    MSBuildNotFound
  }
  $wixsdkdir = "$env:WIX\SDK\VS2017"
  if ($msi -eq $true) {
    Write-Output 'Looking for WiX installation for Visual Studio 2019...'
    if (!(Test-Path -Path $wixsdkdir)) {
      Write-Output 'Failed to find WiX install for Visual Studio 2019'
      Write-Output 'VS2019 support for WiX is only present starting at version 3.11'
      MSBuildNotFound
    }
    if (!(Test-Path -Path "$vcinstalldir\..\MSBuild\Microsoft\WiX")) {
      Write-Output 'Failed to find the WiX Toolset Visual Studio 2019 Extension'
      MSBuildNotFound
    }
  }
  # check if VS201 is already setup, and for the requested arch
  if ($env:VisualStudioVersion -ne '16.0' -or $env:VSCMD_ARG_TGT_ARCH -ne $target_arch) {
    # need to clear VSINSTALLDIR for vcvarsall to work as expected
    $env:VSINSTALLDIR = ''
    # prevent VsDevCmd.bat from changing the current working directory
    $env:VSCMD_START_DIR = (Get-Location).Path
    $vcvars_call = "$vcinstalldir\Auxiliary\Build\vcvarsall.bat"
    $vcvars_cmd = "`"$vcvars_call`" $vcvarsall_arg"
    Write-Output "calling: $vcvars_cmd"
    RunCmdAndSetEnv $vcvars_cmd
    if ($LASTEXITCODE -eq 1) {
      MSBuildNotFound
    }
  }

  Write-Output "Found MSVS version $env:VisualStudioVersion"

  $env:GYP_MSVS_VERSION = 2019
  $env:platform_toolset = 'v142'
  $project_generated = $false

  # noprojgen                                     -> msbuild
  # projgen                       -> runconfigure -> msbuild
  # !node.sln                     -> runconfigure -> msbuild
  # !.gyp_configure_stamp         -> runconfigure -> msbuild
  # des trucs...
  # errorlevel = 1                -> runconfigure -> msbuild
  # sinon                 -> skip ->              -> msbuild
  # skip                          -> runconfigure -> msbuild

  $configure_args > .tmp_gyp_configure_stamp
  where.exe /R . /T *.gyp? >> .tmp_gyp_configure_stamp
  if ($noprojgen -eq $false) {
    if (
      $projgen -eq $true -or
      !(Test-Path node.sln) -or
      !(Test-Path .\.gyp_configure_stamp) -or
      (Compare-Object (Get-Content .gyp_configure_stamp) (Get-Content .tmp_gyp_configure_stamp))
    ) {
      RunConfigure
    }
    Else {
      SkipConfigure
    }
  }

  Build
}
