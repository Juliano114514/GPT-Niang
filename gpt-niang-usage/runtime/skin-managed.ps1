# Optional skin host integration. Standalone startup never loads this module.
function Test-WidgetUpdateEditor {
  return [bool]($script:audioDialogOpen -or ($script:quoteEditor -and $script:quoteEditor.IsVisible) -or ($script:colorTriggerEditor -and $script:colorTriggerEditor.IsVisible) -or ($script:characterGallery -and $script:characterGallery.IsVisible))
}
function Initialize-SkinManagedTypes {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;
public static class GptSkinPipe {
  static readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
  public static volatile bool Closed;
  public static void Start() {
    Console.InputEncoding = new System.Text.UTF8Encoding(false);
    Console.OutputEncoding = new System.Text.UTF8Encoding(false);
    var thread = new Thread(() => {
      try {
        string line;
        while ((line = Console.ReadLine()) != null) {
          if (line.Length > 65536) { Closed = true; return; }
          if (Lines.Count >= 64) { string ignored; Lines.TryDequeue(out ignored); }
          Lines.Enqueue(line);
        }
      } catch {} finally { Closed = true; }
    });
    thread.IsBackground = true;
    thread.Start();
  }
  public static bool TryRead(out string line) { return Lines.TryDequeue(out line); }
  public static void Send(string line) { try { Console.WriteLine(line); Console.Out.Flush(); } catch { Closed = true; } }
}
public static class GptSkinNotification {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct Data {
    public int cbSize; public IntPtr hWnd; public uint id, flags, callback; public IntPtr icon;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string tip;
    public uint state, stateMask;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string info;
    public uint timeout;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string title;
    public uint infoFlags; public Guid guid; public IntPtr balloonIcon;
  }
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)] static extern bool Shell_NotifyIcon(uint command, ref Data data);
  static Data current;
  public static bool Show(IntPtr owner, IntPtr icon, string title, string text) {
    Hide();
    current = new Data { cbSize=Marshal.SizeOf(typeof(Data)), hWnd=owner, id=1, flags=6,
      icon=icon, tip="ChatGPT QQ Skin", info="", title="" };
    if (!Shell_NotifyIcon(0, ref current)) return false;
    current.flags=0x10; current.timeout=8000; current.infoFlags=0x11; // NIIF_INFO | NIIF_NOSOUND
    current.title=title.Length>63?title.Substring(0,63):title;
    current.info=text.Length>255?text.Substring(0,255):text;
    return Shell_NotifyIcon(1, ref current);
  }
  public static void Hide() { if(current.hWnd!=IntPtr.Zero) { Shell_NotifyIcon(2,ref current); current.hWnd=IntPtr.Zero; } }
}
'@
}

function Send-SkinAction([string]$Action,$Parameters=@{}) {
  $script:skinRequestId++
  [GptSkinPipe]::Send((@{v=1;id=("w"+$PID+":"+$script:skinRequestId);action=$Action;params=$Parameters}|ConvertTo-Json -Depth 12 -Compress))
}

function Initialize-SkinManagedRuntime {
  Initialize-SkinManagedTypes
  $script:skinRequestId=0;$script:skinSnapshot=$null;$script:skinReminders=[Collections.Generic.Queue[object]]::new()
  foreach($name in @('WorkdayOpen','WorkdayText','WorkdaySurface','WorkdayCountdown','WorkdayWater','WorkdayIncome','WorkdayUsage','WorkdayPrimary','WorkdayDrink','WorkdaySettings')){
    $script:ui[$name]=$script:window.FindName($name)
  }
  $script:ui.WorkdayOpen.Visibility=[Windows.Visibility]::Visible
  $script:ui.WorkdayOpen.Add_Click({param($sender,$event)Update-SkinWorkday;Open-WidgetBubble 'workday';$event.Handled=$true})
  $script:ui.WorkdayPrimary.Add_Click({param($sender,$event)if($script:skinSnapshot){Send-SkinAction 'workday.primary' @{revision=$script:skinSnapshot.revision}};Restart-SceneTtl;$event.Handled=$true})
  $script:ui.WorkdayDrink.Add_Click({param($sender,$event)if($script:skinSnapshot){Send-SkinAction 'water.reset' @{revision=$script:skinSnapshot.revision}};Restart-SceneTtl;$event.Handled=$true})
  $script:ui.WorkdaySettings.Add_Click({param($sender,$event)Send-SkinAction 'settings.open';Restart-SceneTtl;$event.Handled=$true})
  $script:skinNotificationTimer=[Windows.Threading.DispatcherTimer]::new()
  $script:skinNotificationTimer.Interval=[TimeSpan]::FromSeconds(9)
  $script:skinNotificationTimer.Add_Tick({$script:skinNotificationTimer.Stop();[GptSkinNotification]::Hide()})
  $script:skinBounceTimer=[Windows.Threading.DispatcherTimer]::new()
  $script:skinBounceTimer.Interval=[TimeSpan]::FromMilliseconds(150)
  $script:skinBounceTimer.Add_Tick({$script:skinBounceTimer.Stop();if(!$script:drag){Animate-Press $false}})
  [GptSkinPipe]::Start()
  Send-SkinAction 'ready' @{completionEnabled=[bool]$script:completionNotificationsEnabled}
}

function Update-SkinWorkday {
  $state=$script:skinSnapshot.workday
  if(!$state){$script:ui.WorkdayCountdown.Text='正在连接上班状态…';$script:ui.WorkdayPrimary.IsEnabled=$false;$script:ui.WorkdayDrink.IsEnabled=$false;return}
  $script:ui.WorkdayPrimary.IsEnabled=$true;$script:ui.WorkdayDrink.IsEnabled=$true
  $now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $settings=$state.settings;$session=$state.session
  $workMs=[double]$settings.workHours*3600000;$overtimeMs=[double]$settings.overtimeHours*3600000;$totalMs=$workMs+$overtimeMs
  $elapsed=0.0;$current=$false;$running=$false
  if($session){
    $end=[double]$session.startedAt+$totalMs
    $endAt=if($null-ne $session.stoppedAt){[Math]::Min([double]$session.stoppedAt,$end)}else{$end}
    $expires=[DateTimeOffset]::FromUnixTimeMilliseconds([long]$endAt).LocalDateTime.Date.AddDays(1)
    $current=[DateTime]::Now-lt $expires
    if($current){
      $stop=if($null-ne $session.stoppedAt){[double]$session.stoppedAt}else{[double]$now}
      $elapsed=[Math]::Max(0,[Math]::Min($stop-[double]$session.startedAt,$totalMs))
      $running=$null-eq $session.stoppedAt -and $elapsed-lt $totalMs
    }
  }
  $phase=if(!$current){'未上班'}elseif(!$running){'已下班'}elseif($elapsed-lt $workMs){'下班'}else{'加班'}
  $remaining=if($running){[Math]::Max(0,([double]$(if($elapsed-lt $workMs){$workMs}else{$totalMs}))-$elapsed)}else{0}
  $minutes=[int][Math]::Ceiling($remaining/60000)
  $script:ui.WorkdayCountdown.Text=$phase+'  '+('{0:00}:{1:00}'-f [int][Math]::Floor($minutes/60),($minutes%60))
  $water=[int][Math]::Max(0,[Math]::Ceiling(([double]$settings.waterMinutes*60000-($now-[double]$state.waterStartedAt))/1000))
  $script:ui.WorkdayWater.Text='喝水  '+('{0:00}:{1:00}'-f [int][Math]::Floor($water/60),($water%60))
  $incomeElapsed=if($running){[Math]::Floor($elapsed/60000)*60000}else{$elapsed}
  $income=[double]$settings.monthlySalary/[double]$settings.workDays*[Math]::Min($incomeElapsed/$workMs,1)
  if($overtimeMs-gt 0 -and $elapsed-ge $totalMs){$income+=[double]$settings.overtimePay}
  $script:ui.WorkdayIncome.Text='今日已赚  ¥'+$income.ToString('N2')
  $tokens=[double]$script:skinSnapshot.usage.totals.today.totalTokens
  $script:ui.WorkdayUsage.Text='本机今日 Token  '+$tokens.ToString('N0')
  $script:ui.WorkdayPrimary.Content=if($running){'下班'}else{'上班'}
}

function Tick-SkinManaged {
  if([GptSkinPipe]::Closed){$script:window.Close();return}
  $line=$null
  for($index=0;$index-lt 64 -and [GptSkinPipe]::TryRead([ref]$line);$index++){
    try {
      $message=$line|ConvertFrom-Json
      if($message.v-ne 1){continue}
      switch([string]$message.type){
        'snapshot' {
          $script:skinSnapshot=$message;$script:status=$message.quota
          foreach($entry in @(@{field='surface';control='WorkdaySurface';property='Background'},@{field='text';control='WorkdayText';property='TextElement.Foreground'})){
            $value=$message.theme.($entry.field)
            if([string]$value-match '^#[a-fA-F0-9]{6}$'){
              $brush=[Windows.Media.BrushConverter]::new().ConvertFromString($value)
              if($entry.field-eq 'surface'){$script:ui.WorkdaySurface.Background=$brush}
              else{[Windows.Documents.TextElement]::SetForeground($script:ui.WorkdayText,$brush)}
            }
          }
          Update-Quota
        }
        'completion' {Receive-CompletionMonitorLine ($message.event|ConvertTo-Json -Compress)}
        'reminder' {
          if($message.id-isnot [string] -or $message.title-isnot [string] -or $message.message-isnot [string]){continue}
          [GptSkinNotification]::Show($script:widgetHandle,[Drawing.SystemIcons]::Information.Handle,$message.title,$message.message)|Out-Null
          $script:skinNotificationTimer.Stop();$script:skinNotificationTimer.Start()
          if($script:skinReminders.Count-lt 4){$script:skinReminders.Enqueue($message)}
        }
        'error' {$script:ui.Status.Text=[string]$message.message;$script:ui.WorkdayCountdown.ToolTip=[string]$message.message}
      }
    }catch{$script:ui.Status.Text='共享状态暂不可用'}
    $line=$null
  }
  if(!$script:collapsed -and $script:bubbleMode-eq 'workday'){Update-SkinWorkday}
}

function Tick-SkinReminder {
  if(!$script:skinReminders.Count -or !$script:window.IsVisible -or !$script:collapsed -or $script:drag -or $script:context.IsOpen -or $script:settingsSizePreview -or $script:completionTemporary -or (Test-WidgetUpdateEditor)){return}
  $next=$script:skinReminders.Dequeue()
  $script:ui.QuoteText.Text=$next.title+[Environment]::NewLine+$next.message;Fit-QuoteText
  Open-WidgetBubble 'reminder'
  Animate-Press $true;$script:skinBounceTimer.Stop();$script:skinBounceTimer.Start()
}

function Stop-SkinManagedRuntime {
  foreach($timer in @($script:skinNotificationTimer,$script:skinBounceTimer)){if($timer){$timer.Stop()}}
  if('GptSkinNotification'-as [type]){[GptSkinNotification]::Hide()}
}
