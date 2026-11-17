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
 Save-DevToolsSettings -Path $file -Settings ([pscustomobject]@{RemoteLogPath='/sdcard/x';ExportPath='D:\Logs';Serial='a1b2c3d4';SaveFolder='D:\Saved logs'})
 $loaded=Read-DevToolsSettings -Path $file
 if($loaded.RemoteLogPath -ne '/sdcard/x' -or $loaded.ExportPath -ne 'D:\Logs' -or $loaded.Serial -ne 'a1b2c3d4' -or $loaded.SaveFolder -ne 'D:\Saved logs'){throw 'Dev tool settings did not round-trip.'}
 # Settings written before the save folder existed still load.
 Save-DevToolsSettings -Path $file -Settings ([pscustomobject]@{RemoteLogPath='/sdcard/x';ExportPath='D:\Logs';Serial=''})
 if((Read-DevToolsSettings -Path $file).SaveFolder -ne ''){throw 'Older settings without a save folder regressed.'}
 Set-Content -LiteralPath $file -Value '{broken' -Encoding ASCII
 if((Read-DevToolsSettings -Path $file).RemoteLogPath -ne $defaults.RemoteLogPath){throw 'Broken settings must fall back to defaults.'}
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}

# Every text the window uses exists in text.json.
$text=[IO.File]::ReadAllText((Join-Path $root 'dev-tools\text.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
$source=[IO.File]::ReadAllText((Join-Path $root 'dev-tools\DevTools.ps1'))+[IO.File]::ReadAllText((Join-Path $root 'codex-floating-button.ps1'))
$missing=@([regex]::Matches($source,'\$(?:T|devToolsText)\.([A-Za-z]+)')|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique|Where-Object{$null -eq $text.PSObject.Properties[$_]})
if($missing.Count){throw ('Missing dev tool texts: '+($missing -join ', '))}

Write-Output 'PASS: Dev tools parse adb output, pick Gradle processes, check paths and keep settings.'
