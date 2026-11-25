$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'dev-tools\dev-tools-core.ps1')

# Phones: two ready, one waiting for authorisation, with adb's own banner lines mixed in.
$list=@"
* daemon not running; starting now at tcp:5037
* daemon started successfully
List of devices attached
R5CT00TEST1            device product:r0qzcx model:SM_S9010 device:r0q transport_id:4
a1b2c3d4                device product:umi model:Mi_10 device:umi transport_id:2
emulator-5554          unauthorized transport_id:7

"@
$devices=@(ConvertFrom-AdbDeviceList -Text $list)
if(($devices|ForEach-Object{$_.Serial+'|'+$_.State+'|'+$_.Model}) -join ';' -ne 'R5CT00TEST1|device|SM S9010;a1b2c3d4|device|Mi 10;emulator-5554|unauthorized|'){throw 'adb device list parsing regressed.'}
if(@(ConvertFrom-AdbDeviceList -Text "List of devices attached`r`n`r`n").Count -ne 0){throw 'An empty device list must give no phones.'}

# Foreground activity, from the newer top-resumed line, the older resumed line, and a focused window.
$modern=@"
    topResumedActivity=ActivityRecord{7a812aa u0 com.example.sdk/.ApLogStressActivity} t4452}
  ResumedActivity: ActivityRecord{1111111 u0 com.other/.Other t1}
"@
$activity=(ConvertFrom-ActivityDump -Text $modern).Activity
if($activity.Component -ne 'com.example.sdk/.ApLogStressActivity' -or $activity.Package -ne 'com.example.sdk' -or $activity.ClassName -ne 'com.example.sdk.ApLogStressActivity'){throw 'Top resumed activity parsing regressed.'}
$old=(ConvertFrom-ActivityDump -Text '    mResumedActivity: ActivityRecord{abc u0 com.example.connect/com.example.shop.ui.MainActivity t12568}').Activity
if($old.ClassName -ne 'com.example.shop.ui.MainActivity' -or $old.Package -ne 'com.example.connect'){throw 'Resumed activity parsing on older Android regressed.'}
if($null -ne (ConvertFrom-ActivityDump -Text '').Activity){throw 'No dump must give no activity.'}
$focus=(ConvertFrom-WindowFocusDump -Text "  mCurrentFocus=Window{3f2 u0 NotificationShade}`n  mFocusedApp=ActivityRecord{9 u0 com.android.settings/.Settings t3}").Activity
if($focus.ClassName -ne 'com.android.settings.Settings'){throw 'Focused window parsing regressed.'}

# Task stacks, as "dumpsys activity activities | grep" prints them on Android 13-16 (Samsung repeats the hierarchy
# and nests the home task) and on Android 9 (TaskRecord).
$taskDump=@"
  * Task{4d8bd9a #12578 type=standard A=10020:com.example.connect U=0 visible=true visibleRequested=true mode=fullscreen translucent=false sz=2}
    topResumedActivity=ActivityRecord{227387628 u0 com.example.connect/com.example.shop.ui.activity.register.SignUpEmailActivity t12578}
    * Hist  #1: ActivityRecord{227387628 u0 com.example.connect/com.example.shop.ui.activity.register.SignUpEmailActivity t12578}
      rootOfTask=false task=Task{4d8bd9a #12578 type=standard A=10020:com.example.connect}
    * Hist  #0: ActivityRecord{164081443 u0 com.example.connect/com.example.shop.ui.activity.welcome.WelcomeActivity t12578}
  * Task{34665b9 #1 type=home U=0 visible=false visibleRequested=false mode=fullscreen translucent=false sz=1}
    * Task{84cee30 #12527 type=home I=com.sec.android.app.launcher/.activities.LauncherActivity U=0 rootTaskId=1 visible=false sz=1}
      * Hist  #0: ActivityRecord{36155251 u0 com.sec.android.app.launcher/.activities.LauncherActivity t12527}
  * Task{99b4ae #4452 type=standard A=10429:com.example.sdk U=0 visible=false sz=2}
    * Hist  #1: ActivityRecord{7a812aa u0 com.example.sdk/.ApLogStressActivity} t4452}
    * Hist  #0: ActivityRecord{1a221d1 u0 com.example.sdk/.MainActivity} t4452}
  * Task{b4feb0 #4 type=undefined U=0 rootTaskId=2 visible=false mode=multi-window sz=0}
    Resumed: ActivityRecord{227387628 u0 com.example.connect/com.example.shop.ui.activity.register.SignUpEmailActivity t12578}
  topDisplayFocusedRootTask=Task{4d8bd9a #12578 type=standard A=10020:com.example.connect}
      * Task{4d8bd9a #12578 type=standard A=10020:com.example.connect U=0 visible=true sz=2}
        * ActivityRecord{227387628 u0 com.example.connect/com.example.shop.ui.activity.register.SignUpEmailActivity t12578}
"@
$tasks=@(ConvertFrom-TaskDump -Text $taskDump)
if(($tasks|ForEach-Object{[string]$_.Id+'|'+$_.Type+'|'+$_.Affinity+'|'+$_.Visible+'|'+$_.Activities.Count}) -join ';' -ne '12578|standard|com.example.connect|True|2;12527|home|com.sec.android.app.launcher|False|1;4452|standard|com.example.sdk|False|2'){throw "Task stack parsing regressed: $(($tasks|ForEach-Object{[string]$_.Id+'|'+$_.Activities.Count}) -join ';')"}
if(($tasks[0].Activities|ForEach-Object{$_.ShortName+'|'+$_.Resumed}) -join ',' -ne 'SignUpEmailActivity|True,WelcomeActivity|False'){throw 'Task activities must run from the top of the stack and mark the one on screen.'}
if(($tasks[2].Activities|ForEach-Object ClassName) -join ',' -ne 'com.example.sdk.ApLogStressActivity,com.example.sdk.MainActivity' -or $tasks[2].Activities[0].Resumed){throw 'Short activity names in a task regressed.'}
$oldDump=@"
    * TaskRecord{8f3fd0e #4 A=com.example.app U=0 StackId=1 sz=2}
      * Hist #1: ActivityRecord{c1 u0 com.example.app/.DetailActivity t4}
      * Hist #0: ActivityRecord{c0 u0 com.example.app/.MainActivity t4}
    mResumedActivity: ActivityRecord{c1 u0 com.example.app/.DetailActivity t4}
"@
$old=@(ConvertFrom-TaskDump -Text $oldDump)
if($old.Count -ne 1 -or $old[0].Affinity -ne 'com.example.app' -or ($old[0].Activities|ForEach-Object{$_.ShortName+'|'+$_.Resumed}) -join ',' -ne 'DetailActivity|True,MainActivity|False'){throw 'Android 9 task stacks regressed.'}
if(@(ConvertFrom-TaskDump -Text '').Count -ne 0){throw 'No dump must give no task stacks.'}

# Gradle: daemons, wrapper, worker and Kotlin daemon are stopped; Android Studio and other Java programs are not.
$processes=@(
 [pscustomobject]@{ProcessId=1;Name='java.exe';CommandLine='java -cp C:\u\.gradle\wrapper\dists\gradle-8.7-bin\x\gradle-8.7\lib\gradle-launcher-8.7.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.7'},
 [pscustomobject]@{ProcessId=2;Name='java.exe';CommandLine='java -cp kotlin-compiler-embeddable-1.9.24.jar org.jetbrains.kotlin.daemon.KotlinCompileDaemon --daemon-runFilesPath x'},
 [pscustomobject]@{ProcessId=3;Name='java.exe';CommandLine='java -classpath gradle\wrapper\gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain assembleDebug'},
 [pscustomobject]@{ProcessId=4;Name='java.exe';CommandLine='java worker.org.gradle.process.internal.worker.GradleWorkerMain'},
 [pscustomobject]@{ProcessId=5;Name='studio64.exe';CommandLine='studio64.exe'},
 [pscustomobject]@{ProcessId=6;Name='java.exe';CommandLine='java -jar example-server.jar'},
 [pscustomobject]@{ProcessId=7;Name='javaw.exe';CommandLine=$null},
 [pscustomobject]@{ProcessId=8;Name='java.exe';CommandLine='java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.2'}
)
$gradle=@(Select-GradleProcesses -Processes $processes -ExcludeIds @(8))
if(($gradle|ForEach-Object{[string]$_.ProcessId+'|'+$_.Kind+'|'+$_.Version}) -join ';' -ne '1|Daemon|8.7;2|Kotlin|1.9.24;3|Wrapper|;4|Worker|'){throw 'Gradle process selection regressed.'}

# Paths typed by the user.
foreach($good in '/sdcard/Android/data/com.enplus.caro_sdk/files/BLEBluetoothLog','/sdcard/My Logs'){if(-not (Test-RemoteLogPath -Path $good)){throw "Phone path refused: $good"}}
foreach($bad in '','/','sdcard/x',"/sdcard/x'; rm -rf /sdcard",'/sdcard/$(id)','/sdcard/a;b','/sdcard/a|b','/sdcard/a\b','/sdcard/*'){if(Test-RemoteLogPath -Path $bad){throw "Unsafe phone path accepted: $bad"}}
foreach($good in 'E:\BLELogs','C:\','\\server\share\logs'){if(-not (Test-LocalExportPath -Path $good)){throw "Export path refused: $good"}}
foreach($bad in '','BLELogs','E:','E:BLELogs','E:\a*b','/tmp'){if(Test-LocalExportPath -Path $bad){throw "Bad export path accepted: $bad"}}
if((Get-DeviceFolderName -Model 'Mi 10' -Serial 'a1b2c3d4') -ne 'Mi_10_a1b2c3d4' -or (Get-DeviceFolderName -Model '' -Serial '192.168.1.5:5555') -ne '192_168_1_5_5555'){throw 'Per-phone export folder naming regressed.'}

# Process arguments keep spaces and quotes intact.
$joined=ConvertTo-ProcessArgumentString -Arguments @('-s','a1b2c3d4','shell',"ls -d '/sdcard/My Logs'",'E:\Logs\','say "hi"','')
if($joined -ne "-s a1b2c3d4 shell `"ls -d '/sdcard/My Logs'`" E:\Logs\ `"say \`"hi\`"`" `"`""){throw "Process argument quoting regressed: $joined"}
if((ConvertTo-ProcessArgumentString -Arguments @('C:\My Logs\')) -ne '"C:\My Logs\\"'){throw 'Trailing backslash quoting regressed.'}

# Log files on the phone, newest first, named relative to the log folder.
$stat=@"
2689 1794552622 /sdcard/logs/20261113/ble_info_261113_14_1.log
273064 1794879015 /sdcard/logs/20261117/ble_info_261117_09_1.log
not a stat line
1391 1794553268 /sdcard/logs/20261113/ble_info_261113_15_1.log
"@
$files=@(ConvertFrom-RemoteFileStat -Text $stat -Root '/sdcard/logs/')
if(($files|ForEach-Object Name) -join ',' -ne '20261117/ble_info_261117_09_1.log,20261113/ble_info_261113_15_1.log,20261113/ble_info_261113_14_1.log' -or $files[0].Size -ne 273064){throw 'Phone log listing regressed.'}
if(($files|ForEach-Object Leaf) -join ',' -ne 'ble_info_261117_09_1.log,ble_info_261113_15_1.log,ble_info_261113_14_1.log'){throw 'Phone log file names regressed.'}

# Log tags of different widths are padded so the boxes after them start in the same column.
$raw=@(
 ('[2026-11-16 16:40:57.897] [CONNECT] '+[char]0x250C+'----'),
 ('[2026-11-16 16:40:57.897] [DISCONNECT] '+[char]0x2502+'Thread: main'),
 '[2026-11-17 09:01:40.806]  [android_13_V1.0.0]',
 'Manufacturer:Xiaomi Brand:Xiaomi'
)
$aligned=@(Format-LogLines -Lines $raw)
if($aligned[0] -ne ('[2026-11-16 16:40:57.897] [CONNECT]    '+[char]0x250C+'----') -or $aligned[1] -ne ('[2026-11-16 16:40:57.897] [DISCONNECT] '+[char]0x2502+'Thread: main')){throw "Log tag alignment regressed: $($aligned[0]) | $($aligned[1])"}
if($aligned[0].IndexOf([char]0x250C) -ne $aligned[1].IndexOf([char]0x2502)){throw 'Aligned log boxes do not start in the same column.'}
if($aligned[2] -ne $raw[2] -or $aligned[3] -ne $raw[3]){throw 'Lines without a tag must stay unchanged.'}
if((@(Format-LogLines -Lines @('plain','text')) -join '|') -ne 'plain|text'){throw 'Logs without tags must stay unchanged.'}
if((Format-ByteSize -Bytes 512) -ne '512 B' -or (Format-ByteSize -Bytes 1500) -notmatch '^2 KB$' -or (Format-ByteSize -Bytes 5242088) -notmatch '^5[.,]0 MB$'){throw 'File size formatting regressed.'}

# Browsing phone folders: paths, parents and a folder listing (folders first, newest first).
if((ConvertTo-RemotePath -Path ' /sdcard//Download/ ') -ne '/sdcard/Download' -or (ConvertTo-RemotePath -Path '/') -ne '/'){throw 'Phone path cleaning regressed.'}
if((Get-RemoteParentPath -Path '/sdcard/Download') -ne '/sdcard' -or (Get-RemoteParentPath -Path '/sdcard') -ne '/' -or $null -ne (Get-RemoteParentPath -Path '/')){throw 'Phone parent folder regressed.'}
if((Join-RemotePath -Directory '/' -Name 'sdcard') -ne '/sdcard' -or (Join-RemotePath -Directory '/sdcard/' -Name 'a.log') -ne '/sdcard/a.log'){throw 'Phone path joining regressed.'}
if(-not (Test-RemoteBrowsePath -Path '/') -or (Test-RemoteBrowsePath -Path "/x'y") -or (Test-RemoteBrowsePath -Path 'sdcard')){throw 'Browse path check regressed.'}
$listing=@"
directory|3452|1794223900|./20261109
regular file|5266|1794500000|./notes.txt
directory|3452|1794312167|./20261110
regular file|10|1794600000|./ble_info.log
bad line
directory|3452|1689590474|./My Music
"@
$entries=@(ConvertFrom-RemoteDirListing -Text $listing -Directory '/sdcard/logs')
if(($entries|ForEach-Object{$_.Name+'|'+$_.IsDirectory}) -join ';' -ne '20261110|True;20261109|True;My Music|True;ble_info.log|False;notes.txt|False'){throw 'Phone folder listing regressed.'}
if($entries[2].Path -ne '/sdcard/logs/My Music' -or $entries[3].Size -ne 10){throw 'Phone folder entry details regressed.'}
if(-not (Test-TextContent -Bytes ([Text.Encoding]::UTF8.GetBytes('[INFO] ok'))) -or (Test-TextContent -Bytes ([byte[]](0x89,0x50,0x4E,0x47,0,0)))){throw 'Text file detection regressed.'}

# Long screenshot: screens of a scrolling page with a fixed header and bottom bar are found and joined back
# into the whole page. The page has blank gaps, which must not confuse the matching, and like Samsung lists
# each screen draws a corner effect over the last rows above the bottom bar, which must not end up in the joins.
Add-Type -AssemblyName System.Drawing
$random=New-Object Random 7
$page=New-Object System.Drawing.Bitmap(120,700)
for($y=0;$y -lt 700;$y++){
 $blank=($y % 90) -lt 14
 for($x=0;$x -lt 120;$x++){
  $color=if($blank){[System.Drawing.Color]::White}else{[System.Drawing.Color]::FromArgb($random.Next(256),$random.Next(256),$random.Next(256))}
  $page.SetPixel($x,$y,$color)
 }
}
$screenHeight=260;$header=30;$footer=24;$view=$screenHeight-$header-$footer
$scrolls=@(0,120,250,371,494)
$frames=foreach($top in $scrolls){
 $frame=New-Object System.Drawing.Bitmap(120,$screenHeight)
 $g=[System.Drawing.Graphics]::FromImage($frame)
 $g.Clear([System.Drawing.Color]::FromArgb(37,99,235))
 $g.FillRectangle([System.Drawing.Brushes]::DimGray,0,$screenHeight-$footer,120,$footer)
 $g.DrawImage($page,[System.Drawing.Rectangle]::new(0,$header,120,$view),[System.Drawing.Rectangle]::new(0,$top,120,$view),[System.Drawing.GraphicsUnit]::Pixel)
 $g.FillRectangle([System.Drawing.Brushes]::Gainsboro,0,$screenHeight-$footer-8,10,8)
 $g.Dispose();$frame
}
$rowHashes=@($frames|ForEach-Object{,(Get-ImageRowHashes -Bitmap $_)})
$static=Get-StaticBottomRows -RowHashes $rowHashes
if($static -ne $footer){throw "Fixed bottom bar height: expected $footer, got $static."}
$offsets=@(0);$joins=@(0)
for($i=1;$i -lt $frames.Count;$i++){
 $offsets+=Find-ScrollOffset -Previous $rowHashes[$i-1] -Next $rowHashes[$i] -ContentBottom ($screenHeight-$static)
 $joins+=Get-JoinRow -Previous $rowHashes[$i-1] -Next $rowHashes[$i] -Offset $offsets[$i] -ContentBottom ($screenHeight-$static)
}
if(($offsets -join ',') -ne '0,120,130,121,123'){throw "Scroll offsets regressed: $($offsets -join ',')"}
if(@($joins|Select-Object -Skip 1|Where-Object{$_ -ne ($screenHeight-$footer-8)}).Count){throw "Joins must sit just above the corner effect: $($joins -join ',')"}
if((Find-ScrollOffset -Previous $rowHashes[4] -Next $rowHashes[4] -ContentBottom ($screenHeight-$static)) -ne 0){throw 'An unmoved screen must report no scroll.'}
$joined=Join-ScrollFrames -Frames $frames -Offsets $offsets -JoinRows $joins
try{
 if($joined.Height -ne ($header+494+$view+$footer)){throw "Joined height regressed: $($joined.Height)"}
 $joinedRows=Get-ImageRowHashes -Bitmap $joined
 $pageRows=Get-ImageRowHashes -Bitmap $page
 # The whole page is there without any corner effect, except on the last screen, which really ends there.
 for($y=0;$y -lt 494+$view-8;$y++){if($joinedRows[$header+$y] -ne $pageRows[$y]){throw "Joined page differs from the original at row $y."}}
 for($k=1;$k -le $footer+8;$k++){if($joinedRows[$joined.Height-$k] -ne $rowHashes[4][$screenHeight-$k]){throw 'The last screen must close the joined image.'}}
}finally{$joined.Dispose();$page.Dispose();foreach($frame in $frames){$frame.Dispose()}}

# Windows that forbid screen capture: the security keyboard on screen counts; a hidden secure window does not.
$windowDump=@"
  Window #9 Window{c1dbf6f u0 InputMethod}:
      fl=NOT_FOCUSABLE LAYOUT_IN_SCREEN SECURE SPLIT_TOUCH HARDWARE_ACCELERATED
      Extra fl=0x0
    mForceSeamlesslyRotate=false seamlesslyRotate: pending=null    isOnScreen=true
  Window #10 Window{979f3c0 u0 com.example.shop/com.example.shop.ui.SignUpPwdActivity}:
      fl=LAYOUT_IN_SCREEN LAYOUT_INSET_DECOR SPLIT_TOUCH HARDWARE_ACCELERATED
    mForceSeamlesslyRotate=false seamlesslyRotate: pending=null    isOnScreen=true
  Window #11 Window{a1 u0 com.example.bank/com.example.bank.PinActivity}:
      fl=SECURE LAYOUT_IN_SCREEN
    mForceSeamlesslyRotate=false seamlesslyRotate: pending=null    isOnScreen=false
"@
if((@(Find-SecureWindows -Text $windowDump) -join ',') -ne 'InputMethod'){throw 'Secure window detection regressed.'}
if(@(Find-SecureWindows -Text '').Count -ne 0){throw 'No dump must give no secure windows.'}

# APK install: APK details from aapt, the version on the phone, the command, and adb's answer in plain terms.
$badging=@"
package: name='com.example.shop' versionCode='11' versionName='1.0.0' platformBuildVersionName='16'
sdkVersion:'24'
targetSdkVersion:'36'
application-label:'Example Shop'
application-debuggable
testOnly='-1'
"@
$apkInfo=ConvertFrom-ApkBadging -Text $badging
if($apkInfo.Package -ne 'com.example.shop' -or $apkInfo.VersionCode -ne '11' -or $apkInfo.VersionName -ne '1.0.0' -or $apkInfo.Label -ne 'Example Shop' -or $apkInfo.MinSdk -ne '24' -or -not $apkInfo.Debuggable -or -not $apkInfo.TestOnly){throw 'APK details from aapt regressed.'}
$installedApp=ConvertFrom-InstalledPackage -Text "    versionCode=12 minSdk=24 targetSdk=36`n    versionName=1.0.1`n    versionCode=10 minSdk=24"
if($installedApp.VersionCode -ne '12' -or $installedApp.VersionName -ne '1.0.1' -or $null -ne (ConvertFrom-InstalledPackage -Text '')){throw 'Installed version parsing regressed.'}
if(((Get-InstallArguments -Flags 'dr' -ApkPath 'E:\My Apps\a.apk') -join '|') -ne 'install|-r|-d|E:\My Apps\a.apk' -or ((Get-InstallArguments -Flags '' -ApkPath 'a.apk') -join '|') -ne 'install|a.apk'){throw 'Install arguments regressed.'}
$cases=@(
 @("Performing Streamed Install`nSuccess",0,$true,''),
 @("Performing Streamed Install`nadb: failed to install E:\a.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected: Update version code 11 is older than current 12]",1,$false,'INSTALL_FAILED_VERSION_DOWNGRADE'),
 @("adb: failed to install a.apk: Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]",1,$false,'INSTALL_FAILED_USER_RESTRICTED'),
 @("adb: failed to install a.apk: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.example.shop signatures do not match newer version; ignoring!]",1,$false,'INSTALL_FAILED_UPDATE_INCOMPATIBLE'),
 @("adb.exe: device 'ce59467' not found",1,$false,'DEVICE'),
 @("adb: failed to stat E:\gone.apk: No such file or directory",1,$false,'NO_FILE'),
 @("adb: failed to install a.apk: Failure [-99]",1,$false,'UNKNOWN')
)
foreach($case in $cases){
 $answer=ConvertFrom-InstallOutput -Text $case[0] -ExitCode $case[1]
 if($answer.Success -ne $case[2] -or $answer.Code -ne $case[3]){throw "Install result parsing regressed for: $($case[0])"}
}
if((ConvertFrom-InstallOutput -Text $cases[1][0] -ExitCode 1).Message -notlike 'adb: failed to install*Downgrade detected*'){throw 'The English install message must be kept as adb printed it.'}
# Clearing the data: the old version is uninstalled first, so -r is dropped and -r / -d are not asked for.
if(((Get-InstallArguments -Flags 'rct' -ApkPath 'a.apk') -join '|') -ne 'install|-t|a.apk'){throw 'Clear-data install must not keep the data with -r.'}
if(((Get-InstallWarnings -Apk ([pscustomobject]@{TestOnly=$true;VersionCode='1'}) -Installed ([pscustomobject]@{VersionCode='5'}) -Flags 'c') -join '') -ne 't'){throw 'Clear-data install warnings regressed.'}
$removals=@(
 @("Success",0,'Removed',''),
 @("Failure [not installed for 0]",1,'NotInstalled',''),
 @("Failure [DELETE_FAILED_INTERNAL_ERROR]",1,'Failed','DELETE_FAILED_INTERNAL_ERROR'),
 @("Failure [DELETE_FAILED_DEVICE_POLICY_MANAGER]",1,'Failed','DELETE_FAILED_DEVICE_POLICY_MANAGER'),
 @("adb.exe: device 'x' not found",1,'Failed','DEVICE')
)
foreach($case in $removals){
 $removed=ConvertFrom-UninstallOutput -Text $case[0] -ExitCode $case[1]
 if($removed.Result -ne $case[2] -or $removed.Code -ne $case[3]){throw "Uninstall result parsing regressed for: $($case[0])"}
}
if(-not (Test-ApkTestOnly -Text "E: application (line=17)`n  A: android:testOnly(0x01010272)=(type 0x12)0xffffffff") -or (Test-ApkTestOnly -Text "A: android:testOnly(0x01010272)=(type 0x12)0x0")){throw 'testOnly detection regressed.'}
$apk=[pscustomobject]@{TestOnly=$true;VersionCode='11'};$phone=[pscustomobject]@{VersionCode='12';VersionName='1.0.1'}
if(((Get-InstallWarnings -Apk $apk -Installed $phone -Flags '') -join '') -ne 'trd' -or @(Get-InstallWarnings -Apk $apk -Installed $phone -Flags 'rtd').Count -ne 0 -or @(Get-InstallWarnings -Apk ([pscustomobject]@{TestOnly=$false;VersionCode='12'}) -Installed $null -Flags '').Count -ne 0){throw 'Install warnings regressed.'}
$texts=[IO.File]::ReadAllText((Join-Path $root 'dev-tools\text.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
foreach($key in 'ApkWarnT','ApkWarnR','ApkWarnD'){if($null -eq $texts.PSObject.Properties[$key]){throw "Missing text $key"}}
foreach($code in 'DEVICE','NO_FILE','TIMEOUT','INSTALL_FAILED_VERSION_DOWNGRADE','INSTALL_FAILED_TEST_ONLY','INSTALL_FAILED_ALREADY_EXISTS'){
 $entry=$texts.ApkErrors.PSObject.Properties[$code]
 if($null -eq $entry -or @($entry.Value).Count -ne 2){throw "Missing plain explanation for install error $code"}
}
foreach($key in 'ApkFlagR','ApkFlagC','ApkFlagT','ApkFlagD'){if($null -eq $texts.PSObject.Properties[$key]){throw "Missing text $key"}}
foreach($code in 'DELETE_FAILED_INTERNAL_ERROR','DEVICE','TIMEOUT'){if(@($texts.UninstallErrors.PSObject.Properties[$code].Value).Count -ne 2){throw "Missing plain explanation for uninstall error $code"}}

# AP logs from an app's private folder: package names, relative listings, and safe local names.
foreach($good in 'energy.octopus.installer','com.example.app_debug'){if(-not (Test-AndroidPackageName -Name $good)){throw "Package name refused: $good"}}
foreach($bad in '','octopus','com.example;rm -rf','com..example','1com.example','com.example app'){if(Test-AndroidPackageName -Name $bad){throw "Bad package name accepted: $bad"}}
$apStat=@"
321700 1794880000 cache/charger_logs/SN10000000000001/SN10000000000001_20261117.zip
1024 1794870000 cache/charger_logs/SN10000000000001/log.txt.download
2048 1794860000 cache/charger_logs/unknown_EV-AP/a b.log
"@
$apFiles=@(ConvertFrom-RemoteFileStat -Text $apStat -Root 'cache/charger_logs' | Where-Object { -not $_.Name.EndsWith('.download') })
if(($apFiles|ForEach-Object{$_.Name+'|'+$_.Size}) -join ';' -ne 'SN10000000000001/SN10000000000001_20261117.zip|321700;unknown_EV-AP/a b.log|2048' -or $apFiles[0].Path -ne 'cache/charger_logs/SN10000000000001/SN10000000000001_20261117.zip'){throw 'AP log listing regressed.'}
if((ConvertTo-LocalRelativePath -Name 'SN1/a:b?.zip') -ne 'SN1\a_b_.zip' -or (ConvertTo-LocalRelativePath -Name '../x/./y.log.') -ne 'x\y.log'){throw 'Local names for AP logs regressed.'}

# Filtering log lines ignores case and keeps order.
$filtered=@(Select-LogLines -Lines @('Connect ok','scan','CONNECT lost') -Filter 'connect')
if(($filtered -join '|') -ne 'Connect ok|CONNECT lost' -or @(Select-LogLines -Lines @('a','b') -Filter '').Count -ne 2){throw 'Log line filtering regressed.'}

# Settings: saved values come back; missing or broken files fall back to the defaults.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('dev-tools-test-'+[guid]::NewGuid().ToString('N'))
try{
 $file=Join-Path $temp 'dev-tools.json'
 $defaults=Read-DevToolsSettings -Path $file
 if($defaults.RemoteLogPath -ne '/sdcard/Android/data/com.enplus.caro_sdk/files/BLEBluetoothLog' -or -not $defaults.ExportPath){throw 'Default dev tool settings regressed.'}
 if($defaults.SaveFolder -ne ''){throw 'The save folder must start empty.'}
 if($defaults.ApLogPackage -ne 'energy.octopus.installer'){throw 'Default AP log app regressed.'}
 if($defaults.InstallFlags -ne 'r' -or $defaults.ApkFolder -ne ''){throw 'Default install options regressed.'}
 if($defaults.InstallerEnv -ne 'dev' -or $defaults.InstallerEmail -ne '' -or $defaults.InstallerPassword -ne ''){throw 'The account tool must start on dev with no saved account.'}
 Save-DevToolsSettings -Path $file -Settings ([pscustomobject]@{RemoteLogPath='/sdcard/x';ExportPath='D:\Logs';Serial='';InstallerEnv='pre';InstallerEmail='tester@example.com';InstallerPassword='c2VjcmV0'})
 $account=Read-DevToolsSettings -Path $file
 if($account.InstallerEnv -ne 'pre' -or $account.InstallerEmail -ne 'tester@example.com' -or $account.InstallerPassword -ne 'c2VjcmV0'){throw 'Account settings did not round-trip.'}
 [IO.File]::WriteAllText($file,'{"InstallerEnv":"prod"}')
 if((Read-DevToolsSettings -Path $file).InstallerEnv -ne 'dev'){throw 'An unknown server must fall back to dev.'}
 Save-DevToolsSettings -Path $file -Settings ([pscustomobject]@{RemoteLogPath='/sdcard/x';ExportPath='D:\Logs';Serial='';InstallFlags='rctd';ApkFolder='E:\apks'})
 $flagsLoaded=Read-DevToolsSettings -Path $file
 if($flagsLoaded.InstallFlags -ne 'rctd' -or $flagsLoaded.ApkFolder -ne 'E:\apks'){throw 'Install options did not round-trip.'}
 [IO.File]::WriteAllText($file,'{"InstallFlags":"rx; rm"}')
 if((Read-DevToolsSettings -Path $file).InstallFlags -ne 'r'){throw 'Invalid install options must fall back to the default.'}
 Save-DevToolsSettings -Path $file -Settings ([pscustomobject]@{RemoteLogPath='/sdcard/x';ExportPath='D:\Logs';Serial='a1b2c3d4';SaveFolder='D:\Saved logs';ApLogPackage='com.example.debug'})
 $loaded=Read-DevToolsSettings -Path $file
 if($loaded.RemoteLogPath -ne '/sdcard/x' -or $loaded.ExportPath -ne 'D:\Logs' -or $loaded.Serial -ne 'a1b2c3d4' -or $loaded.SaveFolder -ne 'D:\Saved logs' -or $loaded.ApLogPackage -ne 'com.example.debug'){throw 'Dev tool settings did not round-trip.'}
 # Settings written before the save folder existed still load.
 Save-DevToolsSettings -Path $file -Settings ([pscustomobject]@{RemoteLogPath='/sdcard/x';ExportPath='D:\Logs';Serial=''})
 if((Read-DevToolsSettings -Path $file).SaveFolder -ne ''){throw 'Older settings without a save folder regressed.'}
 Set-Content -LiteralPath $file -Value '{broken' -Encoding ASCII
 if((Read-DevToolsSettings -Path $file).RemoteLogPath -ne $defaults.RemoteLogPath){throw 'Broken settings must fall back to defaults.'}
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

# Installer account: the app's encryption, the server's replies, the token in the phone's log, the saved password.
$hosts=Get-InstallerApiHosts
if((@($hosts.Keys) -join ',') -ne 'dev,pre' -or @($hosts.Values | Where-Object { $_ -notmatch '^https://[^/]+/.+/$' }).Count){throw 'Installer servers regressed.'}
Initialize-InstallerEcc
$hex={param([byte[]]$Bytes) ($Bytes|ForEach-Object{$_.ToString('x2')}) -join ''}
$zeroKey=New-Object byte[] 32;$zeroIv=New-Object byte[] 12
# AES-256-GCM test cases 13 and 14 from the GCM specification.
if((& $hex ([InstallerEcc]::GcmEncrypt($zeroKey,$zeroIv,(New-Object byte[] 0),(New-Object byte[] 0)))) -ne '530f8afbc74536b9a963b4f1c4cb738b'){throw 'AES-GCM test case 13 regressed.'}
if((& $hex ([InstallerEcc]::GcmEncrypt($zeroKey,$zeroIv,(New-Object byte[] 16),(New-Object byte[] 0)))) -ne 'cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919'){throw 'AES-GCM test case 14 regressed.'}
$point=Get-InstallerServerPoint
if($point.Length -ne 65 -or $point[0] -ne 4){throw 'The server key must be an uncompressed P-256 point.'}
# A round trip with a test server key: the server side derives the same key and reads the email back.
$serverKey=New-Object System.Security.Cryptography.ECDiffieHellmanCng(256)
try{
 $serverKey.KeyDerivationFunction=[System.Security.Cryptography.ECDiffieHellmanKeyDerivationFunction]::Hmac
 $serverKey.HashAlgorithm=[System.Security.Cryptography.CngAlgorithm]::Sha256
 $serverKey.HmacKey=New-Object byte[] 32
 $blob=$serverKey.PublicKey.ToByteArray()
 $testPoint=New-Object byte[] 65;$testPoint[0]=4;[Array]::Copy($blob,8,$testPoint,1,64)
 $sealed=[Convert]::FromBase64String((ConvertTo-InstallerCipherText -Text 'tester@example.com' -ServerPoint $testPoint))
 if($sealed.Length -ne 65+12+18+16 -or $sealed[0] -ne 4){throw 'An encrypted field has the wrong layout.'}
 $eph=[byte[]]$sealed[0..64];$iv=[byte[]]$sealed[65..76];$body=[byte[]]$sealed[77..($sealed.Length-1)]
 $ephBlob=New-Object byte[] 72;[BitConverter]::GetBytes(0x314B4345).CopyTo($ephBlob,0);[BitConverter]::GetBytes(32).CopyTo($ephBlob,4);[Array]::Copy($eph,1,$ephBlob,8,64)
 $ephKey=[System.Security.Cryptography.ECDiffieHellmanCngPublicKey]::FromByteArray($ephBlob,[System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
 $prk=$serverKey.DeriveKeyMaterial($ephKey)
 $hmac=[System.Security.Cryptography.HMACSHA256]::new($prk)
 $key=$hmac.ComputeHash([byte[]]($eph+[byte]1));$hmac.Dispose()
 $cipher=[byte[]]$body[0..($body.Length-17)]
 $opened=[InstallerEcc]::GcmEncrypt($key,$iv,$cipher,$eph)
 $plain=[byte[]]$opened[0..($cipher.Length-1)]
 if([Text.Encoding]::UTF8.GetString($plain) -ne 'tester@example.com'){throw 'The server side could not decrypt the field.'}
 if((& $hex ([InstallerEcc]::GcmEncrypt($key,$iv,$plain,$eph))) -ne (& $hex $body)){throw 'The authentication tag does not match.'}
}finally{$serverKey.Dispose()}
if((ConvertTo-InstallerCipherText -Text 'same') -eq (ConvertTo-InstallerCipherText -Text 'same')){throw 'Each encryption must use a fresh key and IV.'}

$ok=ConvertFrom-InstallerResponse -Text '{"code":2000,"message":"success","data":{"token":"tok-123","userId":42}}'
if(-not $ok.Ok -or $ok.Token -ne 'tok-123' -or $ok.UserId -ne '42' -or $ok.Message -ne 'success'){throw 'Sign-in reply parsing regressed.'}
$bad=ConvertFrom-InstallerResponse -Text '{"code":4001,"msg":"Incorrect password","data":null}'
if($bad.Ok -or $bad.Code -ne '4001' -or $bad.Message -ne 'Incorrect password' -or $bad.Token){throw 'Failed reply parsing regressed.'}
$gateway=ConvertFrom-InstallerResponse -Text '<html>Bad Gateway</html>' -StatusCode 502
if($gateway.Ok -or $gateway.Code -ne 'HTTP 502' -or $gateway.Raw -ne '<html>Bad Gateway</html>'){throw 'A reply that is not JSON must keep the HTTP status.'}
if((ConvertFrom-InstallerResponse -Text '{"code":2000}' -StatusCode 500).Ok){throw 'An HTTP error is never a success.'}

$logcat=@"
11-19 10:00:01.100  1234  5678 I HttpLog : HttpLog-Response-1a2b {"code":2000,"data":{"token":"old-token","userId":11}}
11-19 10:00:02.000  1234  5678 I Other   : unrelated "token":"not-http"
11-19 10:05:01.100  1234  5678 I HttpLog : HttpLog-Response-3c4d {"code":2000,"data":{"token":"tok-new","userId":42,
11-19 10:05:01.101  1234  5678 I HttpLog : HttpLog-Response-3c4d "email":"tester@example.com"}}
11-19 10:05:01.102  1234  5678 I HttpLog : HttpLog-Response-3c4de {"userId":99,"email":"other@example.com"}
"@
$found=ConvertFrom-InstallerLogcat -Text $logcat
if($null -eq $found -or $found.Token -ne 'tok-new' -or $found.UserId -ne '42' -or $found.Email -ne 'tester@example.com'){throw 'Token from the phone log regressed.'}
if($null -ne (ConvertFrom-InstallerLogcat -Text "11-19 I Other: `"token`":`"x`"")){throw 'Only HttpLog responses may give a token.'}
if((Format-TokenPreview -Token 'abcdef1234567890wxyz') -ne ('abcdef'+[char]0x2026+'wxyz') -or (Format-TokenPreview -Token 'short') -ne 'short'){throw 'Token preview regressed.'}

$secret=Protect-DevToolsSecret -Text 'not-a-real-password'
if(-not $secret -or $secret.Contains('not-a-real')){throw 'The password must not be saved as plain text.'}
if((Unprotect-DevToolsSecret -Text $secret) -ne 'not-a-real-password'){throw 'The saved password did not round-trip.'}
if((Unprotect-DevToolsSecret -Text 'AAAA') -ne '' -or (Protect-DevToolsSecret -Text '') -ne ''){throw 'An unreadable or empty saved password must come back empty.'}

# BLE log analyzer: one command round trip in the SDK's log-file format, the same in logcat format, and bare frames.
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $root 'dev-tools\ble-analyzer.ps1')
Initialize-BleAnalyzer
$box=@{Top=[string][char]0x250C;Side=[string][char]0x2502;Mid=[string][char]0x251C;Bottom=[string][char]0x2514}
$blocks=@(
 @('13:24:30.544','SEND',@('[mac:AA:BB:CC:DD:EE:FF] command_start','Cmd=0xAA commandSequence=86 retryPolicy=SEND_ONCE','caller=com.example.app.BleClient.enableAteMode(BleClient.kt:108)')),
 @('13:24:30.545','SEND',@('[mac:AA:BB:CC:DD:EE:FF] send_frame 0xFB065600AA0500181F0100227204','Cmd=0xAA commandSequence=86 length=14 packet=1/1 protocol=plain')),
 @('13:24:30.875','RECV',@('[mac:AA:BB:CC:DD:EE:FF] receive_frame 0xFB0656000A0500141F010022687D','Cmd=0x0A commandSequence=86 length=14 packet=1/1 route=response protocol=plain responseTimeMs=330')),
 @('13:24:30.878','RECV',@('[mac:AA:BB:CC:DD:EE:FF] command_success','Cmd=0xAA commandSequence=86 responseCmd=0x0A responseBusinessSeq=86 retries=0 durationMs=333'))
)
$fileLines=New-Object System.Collections.Generic.List[string]
$logcatLines=New-Object System.Collections.Generic.List[string]
foreach($block in $blocks){
 $stamp='[2026-11-20 '+$block[0]+'] ['+$block[1]+'] '
 $epoch='  1795143070.'+$block[0].Substring(9)+'000  8177  8177 D lib-log : '
 $body=@($box.Top+'----',$box.Side+'Thread: main',$box.Mid+'----')+@($block[2]|ForEach-Object{$box.Side+$_})+@($box.Bottom+'----')
 foreach($line in $body){
  $fileLines.Add($stamp+$line)
  $logcatLines.Add($epoch+$(if($line.StartsWith($box.Side)){$box.Side+'['+$block[1]+'] '+$line.Substring(1)}else{$line}))
 }
}
function Read-BleRecords([string[]]$Lines){
 $parser=New-Object Codex.Ble.BleLogParser
 $seen=New-Object 'System.Collections.Generic.HashSet[object]'
 foreach($line in $Lines){foreach($record in $parser.Feed($line)){[void]$seen.Add($record)}}
 foreach($record in $parser.Flush()){[void]$seen.Add($record)}
 return @($seen)
}
foreach($case in @(@('log file',$fileLines.ToArray()),@('logcat',$logcatLines.ToArray()))){
 $records=@(Read-BleRecords -Lines $case[1])
 if($records.Count -ne 1){throw "BLE $($case[0]) format: expected one round trip, got $($records.Count)."}
 $trip=$records[0]
 if($trip.State -ne 'Success' -or $trip.Send.Command -ne 0xAA -or $trip.Receive.Command -ne 0x0A -or -not $trip.Send.ChecksumOk -or -not $trip.Receive.ChecksumOk){throw "BLE $($case[0]) format: round trip not matched ($($trip.State))."}
 if($trip.Caller -notmatch 'enableAteMode' -or $trip.SdkElapsedMs -ne 330 -or [int]$trip.ElapsedMs -ne 330 -or -not $trip.Receive.Result){throw "BLE $($case[0]) format: caller, timing or result missing."}
}
# The log viewer pads the tag; padded lines read the same.
$padded=@($fileLines|ForEach-Object{$_ -replace '\] \[(SEND|RECV)\] ','] [$1]     '})
if(@(Read-BleRecords -Lines $padded).Count -ne 1){throw 'BLE log lines padded by the viewer were not read.'}
# Bare frames, one per line: requests go out, the rest come back, for every command (not only AA / 0A).
$bare=@(Read-BleRecords -Lines @('FB065600AA0500181F0100227204','FB 06 56 00 0A 05 00 14 1F 01 00 22 68 7D','FB065700B60100005298'))
if($bare.Count -ne 2 -or @($bare|Where-Object{$_.Send -and $_.Receive}).Count -ne 1 -or @($bare|Where-Object{$_.Send.Command -eq 0xB6}).Count -ne 1){throw 'Bare BLE frames were not read.'}
$bad=[Codex.Ble.Protocol]::Decode('FB065600AA0500181F0100227205')
if($bad.ChecksumOk -ne $false){throw 'A frame with a wrong CRC16 must fail the check.'}

# Protocol HTML (the PDF converter's format): headings found by size and number, a section cut to its own heading.
$protocolHtml=Join-Path ([IO.Path]::GetTempPath()) ('ble-protocol-test-'+[guid]::NewGuid().ToString('N')+'.html')
$seqTitle=[string][char]0x5E8F+[char]0x53F7;$lenTitle=[string][char]0x957F+[char]0x5EA6;$defTitle=[string][char]0x5B9A+[char]0x4E49
$cell={param($left,$top,$text) '<div class="stl_01" style="left:'+$left+'em;top:'+$top+'em;"><span class="stl_73 stl_08" style="position:relative; top:-2.1699em;">'+$text+'</span></div>'}
$pageLine={param($top,$size,$text) '<div class="stl_01" style="left:7.5em;top:'+$top+'em;"><span class="'+$size+' stl_08" style="position:relative; top:-2.1699em;">'+$text+'</span></div>'}
$protocolText='<!DOCTYPE html><html><head><meta charset="utf-8" /><style>.stl_65 { font-size: 1.329167em; } .stl_73 { font-size: 0.75em; }</style></head><body>'+
 '<div id="page_0" class="stl_ stl_02"><div class="stl_view">'+(& $pageLine 10 'stl_65' '2.5 cmd_08 Realtime report')+
 (& $cell 4 12 $seqTitle)+(& $cell 7 12 ($lenTitle+'(Byte)'))+(& $cell 12 12 $defTitle)+(& $cell 5 14 '1')+(& $cell 8 14 '4')+(& $cell 12 14 'order')+(& $cell 5 15.5 '2')+(& $cell 8 15.5 '32')+(& $cell 12 15.5 'card')+'</div></div>'+
 '<div id="page_1" class="stl_ stl_02"><div class="stl_view">'+(& $pageLine 8 'stl_73' 'more fields')+(& $pageLine 30 'stl_65' '2.6 cmd_A8 Realtime request')+(& $pageLine 50 'stl_65' ([char]0x9644+[char]0x5F55+' 5.3: states'))+'</div></div></body></html>'
[IO.File]::WriteAllText($protocolHtml,$protocolText,(New-Object Text.UTF8Encoding($false)))
try{
 $protocolDoc=[Codex.Ble.ProtocolDocument]::Load($protocolHtml)
 if(($protocolDoc.Sections|ForEach-Object{$_.Number}) -join ',' -ne '2.5,2.6,5.3'){throw 'Protocol headings were not found.'}
 $tableRows=@($protocolDoc.FieldRows($protocolDoc.FindCommand(0x08)))
 if(($tableRows|ForEach-Object{$_.Number+':'+$_.Start+'+'+$_.Length+':'+$_.Name}) -join ',' -ne '1:7+4:order,2:11+32:card'){throw 'Protocol table rows were not read.'}
 if($protocolDoc.FindCommand(0x08).Number -ne '2.5' -or $protocolDoc.FindCommand(0xA8).Number -ne '2.6' -or $protocolDoc.FindNumber('5.3').Page -ne 1){throw 'Protocol sections were not matched to commands.'}
 # Each table row has a red frame; only the highlighted one is shown.
 $framedHtml=$protocolDoc.SectionHtml($protocolDoc.FindCommand(0x08), 1)
 if($framedHtml -notmatch 'class="hit" data-row="1" id="row-1" style="[^"]*"' -or $Matches[0] -match 'display:none' -or $framedHtml -notmatch 'data-row="0" id="row-0" style="[^"]*display:none'){throw 'The highlighted protocol row must be framed and the others hidden.'} $sectionHtml=$protocolDoc.SectionHtml($protocolDoc.FindCommand(0x08))
 if(([regex]::Matches($sectionHtml,'class="slice"')).Count -ne 2 -or $sectionHtml -notmatch 'top:-9\.2em' -or $sectionHtml -notmatch 'height:[\d.]+em"><div style="position:absolute;left:0;top:-[\d.]+em">'){throw 'A section must be cut from its heading across its pages.'}
 # The last section starts at its own heading (50 - 0.8) on its single page; the text above it is clipped away.
 $appendixHtml=$protocolDoc.SectionHtml($protocolDoc.FindNumber('5.3'))
 if(([regex]::Matches($appendixHtml,'class="slice"')).Count -ne 1 -or $appendixHtml -notmatch 'top:-49\.2em'){throw 'A section must not show other headings.'}
}finally{Remove-Item -LiteralPath $protocolHtml -Force -ErrorAction SilentlyContinue}

# AI records: one round per typed question, the last text of the round as the answer, the texts before it as the
# process; tool calls, sub-agents and injected skill text are left out; Markdown answers become one-style HTML.
. (Join-Path $root 'dev-tools\ai-records.ps1')
Initialize-AiRecords
$chatDir=Join-Path ([IO.Path]::GetTempPath()) ('ai-records-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $chatDir '.git') -Force | Out-Null
$chatFile=Join-Path $chatDir 'session-1.jsonl'
$cwd=$chatDir.Replace('\','\\')
$chatLines=@(
 '{"type":"custom-title","customTitle":"Example title","sessionId":"session-1"}',
 ('{"type":"user","turnOrigin":"human","isSidechain":false,"timestamp":"2026-11-20T08:00:00.000Z","cwd":"'+$cwd+'","message":{"role":"user","content":"<command-message>lyycode</command-message>\n<command-name>/lyycode</command-name>\n<command-args>save the answers</command-args>"}}'),
 ('{"type":"user","isMeta":true,"timestamp":"2026-11-20T08:00:01.000Z","cwd":"'+$cwd+'","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill"}]}}'),
 ('{"type":"assistant","isSidechain":false,"timestamp":"2026-11-20T08:00:05.000Z","cwd":"'+$cwd+'","message":{"role":"assistant","content":[{"type":"text","text":"Reading the files first."},{"type":"tool_use","name":"Read"}]}}'),
 ('{"type":"user","isSidechain":false,"timestamp":"2026-11-20T08:00:06.000Z","cwd":"'+$cwd+'","message":{"role":"user","content":[{"type":"tool_result","content":"file text"}]}}'),
 ('{"type":"assistant","isSidechain":true,"timestamp":"2026-11-20T08:00:07.000Z","cwd":"'+$cwd+'","message":{"role":"assistant","content":[{"type":"text","text":"sub agent text"}]}}'),
 ('{"type":"assistant","isSidechain":false,"timestamp":"2026-11-20T08:01:00.000Z","cwd":"'+$cwd+'","message":{"role":"assistant","content":[{"type":"text","text":"**Done.**\n\n| Code | Result |\n|---|---|\n| 1 | ok<br>fine |"}]}}'),
 ('{"type":"user","turnOrigin":"human","isSidechain":false,"timestamp":"2026-11-20T09:00:00.000Z","cwd":"'+$cwd+'","message":{"role":"user","content":[{"type":"text","text":"second question"},{"type":"image","source":{}}]}}'),
 ('{"type":"assistant","isSidechain":false,"timestamp":"2026-11-20T09:00:30.000Z","cwd":"'+$cwd+'","message":{"role":"assistant","content":[{"type":"text","text":"- one\n- two\n\n1. first"}]}}')
)
[IO.File]::WriteAllLines($chatFile,$chatLines,(New-Object Text.UTF8Encoding($false)))
try{
 $serializer=New-Object System.Web.Script.Serialization.JavaScriptSerializer
 $chat=[Codex.AiRecords.ChatArchive]::ReadTranscript($chatFile,$serializer)
 if($chat.Title -ne 'Example title' -or $chat.Project -ne (Split-Path -Leaf $chatDir) -or $chat.Records.Count -ne 2){throw "AI records: title, project or rounds wrong ($($chat.Title) / $($chat.Project) / $($chat.Records.Count))."}
 $first=$chat.Records[0]
 if($first.Question -ne '/lyycode save the answers' -or $first.Process.Count -ne 1 -or $first.Process[0] -ne 'Reading the files first.' -or $first.Answer -notmatch '^\*\*Done'){throw 'AI records: the first round was not read as question, process and answer.'}
 if($chat.Records[1].Question -notmatch 'second question' -or $chat.Records[1].Question -notmatch '1'){throw 'AI records: a question with a picture lost its text.'}
 $html=[Codex.AiRecords.MarkdownHtml]::Render($first.Answer)
 if($html -notmatch '<b>Done\.</b>' -or $html -notmatch '<th>Code</th>' -or $html -notmatch '<td>ok<br>fine</td>'){throw 'AI records: Markdown table or bold not rendered.'}
 $lists=[Codex.AiRecords.MarkdownHtml]::Render($chat.Records[1].Answer)
 if($lists -ne '<ul><li>one</li><li>two</li></ul><ol><li>first</li></ol>'){throw "AI records: lists rendered wrong: $lists"}
 if([Codex.AiRecords.MarkdownHtml]::Render('<script>x</script>') -match '<script>'){throw 'AI records: raw HTML in an answer must be escaped.'}
 # Codex questions: a marker cut off by a code span, bold that must touch its text, a literal 2**3.
 $bold=[Codex.AiRecords.MarkdownHtml]::Render('only**`CARO_MAX` ** **all devices** , **Result**x and 2**3')
 if($bold -notmatch '<b>all devices</b>' -or $bold -notmatch '<b>Result</b>x' -or $bold -notmatch '<code>CARO_MAX</code>' -or $bold -notmatch '2\*\*3' -or ($bold -replace '2\*\*3','') -match '\*\*'){throw "AI records: bold markers rendered wrong: $bold"}
 if($chat.Machine -ne $env:COMPUTERNAME){throw 'AI records: a session read here must name this computer.'}

 # Archives are gzip files in <records>\sessions, swapped in whole; the sync status comes from the notes backend.
 $previousRoot=$env:TNOTES_AI_RECORDS
 $env:TNOTES_AI_RECORDS=Join-Path $chatDir 'records'
 try{
  if([Codex.AiRecords.ChatArchive]::ArchiveRoot -ne (Join-Path $env:TNOTES_AI_RECORDS 'sessions')){throw 'AI records: TNOTES_AI_RECORDS is not used.'}
  [void][IO.Directory]::CreateDirectory([Codex.AiRecords.ChatArchive]::ArchiveRoot)
  [Codex.AiRecords.ChatArchive]::WriteArchive($chat,$serializer)
  [Codex.AiRecords.ChatArchive]::WriteArchive($chat,$serializer)
  $stored=[Codex.AiRecords.ChatArchive]::ArchivePath('session-1')
  $bytes=[IO.File]::ReadAllBytes($stored)
  if($bytes[0] -ne 0x1f -or $bytes[1] -ne 0x8b){throw 'AI records: the archive is not gzip-compressed.'}
  if(@(Get-ChildItem -LiteralPath ([Codex.AiRecords.ChatArchive]::ArchiveRoot) -File).Count -ne 1){throw 'AI records: writing an archive left temporary files.'}
  $back=[Codex.AiRecords.ChatArchive]::ReadArchive($stored,$serializer)
  if($back.Records.Count -ne 2 -or $back.Records[0].Answer -ne $first.Answer -or $back.Title -ne 'Example title' -or $back.Machine -ne $env:COMPUTERNAME){throw 'AI records: the compressed archive did not read back the same.'}
  [Codex.AiRecords.ChatArchive]::RequestSync()
  if(-not (Test-Path -LiteralPath ([Codex.AiRecords.ChatArchive]::SyncRequestPath))){throw 'AI records: the sync request file was not written.'}
  if([Codex.AiRecords.ChatArchive]::SyncChanges() -ne 0){throw 'AI records: no status file should mean nothing downloaded.'}
  [IO.File]::WriteAllText([Codex.AiRecords.ChatArchive]::SyncStatusPath,'{"state":"ok","updated":"2026-11-21T06:30:00.000Z","downloaded":2,"codex":1,"stored":530000}')
  if([Codex.AiRecords.ChatArchive]::SyncText() -notmatch ' 518 KB' -or [Codex.AiRecords.ChatArchive]::SyncChanges() -ne 3){throw 'AI records: the sync status was not read.'}
  [IO.File]::WriteAllText([Codex.AiRecords.ChatArchive]::SyncStatusPath,'{"state":"off","message":"server-old","updated":"2026-11-21T06:30:00.000Z","lastSuccess":null}')
  if([Codex.AiRecords.ChatArchive]::SyncText() -ne 'server-old'){throw 'AI records: a sync problem must be shown as the backend wrote it.'}
 }finally{$env:TNOTES_AI_RECORDS=$previousRoot}
}finally{Remove-Item -LiteralPath $chatDir -Recurse -Force -ErrorAction SilentlyContinue}

# The AI records sync (notes backend) between two computers through a fake server.
& node --no-warnings (Join-Path $root 't-notes\tests\ai_sync_test.cjs')
if($LASTEXITCODE -ne 0){throw 'AI records sync test failed.'}
# Codex conversations exported from databases shaped like Codex's own.
& node --no-warnings (Join-Path $root 't-notes\tests\codex_records_test.cjs')
if($LASTEXITCODE -ne 0){throw 'Codex records test failed.'}

# Every text the window uses exists in text.json.
$text=[IO.File]::ReadAllText((Join-Path $root 'dev-tools\text.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
$source=[IO.File]::ReadAllText((Join-Path $root 'dev-tools\DevTools.ps1'))+[IO.File]::ReadAllText((Join-Path $root 'codex-floating-button.ps1'))
$missing=@([regex]::Matches($source,'\$(?:T|devToolsText)\.([A-Za-z]+)')|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique|Where-Object{$null -eq $text.PSObject.Properties[$_]})
if($missing.Count){throw ('Missing dev tool texts: '+($missing -join ', '))}

Write-Output 'PASS: Dev tools parse adb output, pick Gradle processes, check paths, keep settings, encrypt installer sign-ins, read BLE logs and AI conversation records.'
