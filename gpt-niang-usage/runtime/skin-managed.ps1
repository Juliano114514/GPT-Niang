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
using System.Windows.Threading;
public static class GptSkinPipe {
  static readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
  static Dispatcher dispatcher;
  static Action receive;
  static int wakePending;
  public static volatile bool Closed;
  static void Wake() {
    if (dispatcher.HasShutdownStarted || Interlocked.Exchange(ref wakePending, 1) != 0) return;
    try {
      dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => {
        Interlocked.Exchange(ref wakePending, 0);
        receive();
      }));
    } catch { Interlocked.Exchange(ref wakePending, 0); }
  }
  public static void Start(Dispatcher ui, Action onMessage) {
    dispatcher = ui; receive = onMessage;
    Console.InputEncoding = new System.Text.UTF8Encoding(false);
    Console.OutputEncoding = new System.Text.UTF8Encoding(false);
    var thread = new Thread(() => {
      try {
        string line;
        while ((line = Console.ReadLine()) != null) {
          if (line.Length > 65536) { Closed = true; return; }
          if (Lines.Count >= 64) { string ignored; Lines.TryDequeue(out ignored); }
          Lines.Enqueue(line);
          Wake();
        }
      } catch {} finally { Closed = true; Wake(); }
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
'@ -ReferencedAssemblies 'System',([Windows.Threading.Dispatcher].Assembly.Location)
}

function Send-SkinAction([string]$Action,$Parameters=@{}) {
  $script:skinRequestId++
  [GptSkinPipe]::Send((@{v=1;id=("w"+$PID+":"+$script:skinRequestId);action=$Action;params=$Parameters}|ConvertTo-Json -Depth 12 -Compress))
}

function Initialize-SkinManagedRuntime {
  Initialize-SkinManagedTypes
  $script:skinRequestId=0;$script:skinSnapshot=$null;$script:skinReminders=[Collections.Generic.Queue[object]]::new()
  $script:skinHidden=$true;$script:skinOwnerClosed=$false;$script:skinReminderAnimating=$false;$script:skinWorkdaySecond=-1
  foreach($name in @('WorkdayOpen','WorkdayText','WorkdaySurface','WorkdayPhase','WorkdayCountdown','WorkdayWater','WorkdayPrimary','WorkdayDrink','WaterBubble','WaterCountdown','WaterTextFacingScale','CompactTask','CompactTaskTitle','CompactTaskStep','CompactTaskPulse','CompactNotice','CompactNoticeMark','CompactNoticeTitle','CompactNoticePreview')){
    $script:ui[$name]=$script:window.FindName($name)
  }
  $script:ui.WorkdayOpen.Visibility=[Windows.Visibility]::Visible
  $script:ui.WorkdayOpen.Add_Click({param($sender,$event)Update-SkinWorkday;Open-WidgetBubble 'workday';$event.Handled=$true})
  $script:ui.WorkdayPrimary.Add_Click({param($sender,$event)if($script:skinSnapshot){Send-SkinAction 'workday.primary' @{revision=$script:skinSnapshot.revision}};Restart-SceneTtl;$event.Handled=$true})
  $script:ui.WorkdayDrink.Add_Click({param($sender,$event)if($script:skinSnapshot){Send-SkinAction 'water.reset' @{revision=$script:skinSnapshot.revision}};Restart-SceneTtl;$event.Handled=$true})
  $script:ui.WaterBubble.Add_MouseLeftButtonUp({param($sender,$event)Stop-SkinCompactNotice;Update-SkinWorkday;Open-WidgetBubble 'workday';$event.Handled=$true})
  $script:ui.Girl.ToolTip='点角色依次查看上班状态、额度、语录；拖动调整位置；右键设置'
  $script:ui.WaterTextFacingScale.ScaleX=$script:ui.FacingScale.ScaleX
  $script:skinCompactPage=''
  $script:skinCompactTaskId=$null;$script:skinCompactNotice=$null
  $script:skinPlayedTasks=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $script:skinCompactTimer=[Windows.Threading.DispatcherTimer]::new()
  $script:skinCompactTimer.Add_Tick({Update-SkinCompactBubble -Advance})
  $script:skinNoticeTimer=[Windows.Threading.DispatcherTimer]::new()
  $script:skinNoticeTimer.Interval=[TimeSpan]::FromSeconds(5)
  $script:skinNoticeTimer.Add_Tick({Stop-SkinCompactNotice;Update-SkinCompactBubble})
  $script:window.Add_IsVisibleChanged({Update-SkinCompactBubble})
  Set-WidgetIndependentLayout
  $script:window.Add_Closing({param($sender,$event)
    if(!$script:skinOwnerClosed -and !$script:runtimeClosed){$event.Cancel=$true;Hide-SkinWidget}
  })
  $script:skinNotificationTimer=[Windows.Threading.DispatcherTimer]::new()
  $script:skinNotificationTimer.Interval=[TimeSpan]::FromSeconds(9)
  $script:skinNotificationTimer.Add_Tick({$script:skinNotificationTimer.Stop();[GptSkinNotification]::Hide()})
  $script:skinBounceTimer=[Windows.Threading.DispatcherTimer]::new()
  $script:skinBounceTimer.Interval=[TimeSpan]::FromMilliseconds(420)
  $script:skinBounceTimer.Add_Tick({
    $showing=($script:skinCompactNotice -and $script:collapsed) -or (!$script:collapsed -and $script:bubbleMode-eq 'reminder')
    if($script:skinHidden -or !$script:window.IsVisible -or !$showing -or $script:drag -or $script:context.IsOpen){Stop-SkinReminderAnimation;return}
    $script:skinReminderDown=!$script:skinReminderDown
    Animate-Press $script:skinReminderDown
  })
  [GptSkinPipe]::Start($script:window.Dispatcher,[Action]{
    try{Tick-Widget}catch{$script:ui.Status.Text='共享状态暂不可用'}
  })
  Send-SkinAction 'ready' @{completionEnabled=[bool]$script:completionNotificationsEnabled}
}

function Stop-SkinReminderAnimation {
  if(!$script:skinReminderAnimating){return}
  $script:skinReminderAnimating=$false;$script:skinBounceTimer.Stop()
  if(!$script:drag){Animate-Press $false}
}

function Stop-SkinCompactNotice {
  if(!$script:skinCompactNotice){return}
  $script:skinCompactNotice=$null;$script:skinNoticeTimer.Stop()
  Stop-SkinReminderAnimation
}

function Hide-SkinWidget {
  Send-SkinAction 'enable' @{enabled=$false}
  Set-SkinWidgetVisibility $false
}

function Set-SkinWidgetVisibility([bool]$Visible) {
  $script:skinHidden=!$Visible
  if(!$Visible){
    Stop-SkinCompactNotice
    Update-SkinCompactBubble
    Stop-SkinReminderAnimation
    Pause-CompletionNotification
    if($script:widgetMusic -and $script:widgetMusic.Enabled){Stop-WidgetMusic}
    if(!$script:collapsed){Hide-Quota}
    $script:hostFollower.Suspend();$script:occlusionRecovery.Configure([IntPtr]::Zero,$false)
    $script:context.IsOpen=$false
    foreach($editor in @($script:quoteEditor,$script:colorTriggerEditor,$script:characterGallery)){if($editor -and $editor.IsVisible){$editor.Hide()}}
    $script:window.Hide()
  }
  $script:lastPosition=$null
}

function Set-SkinStepPulse([bool]$Visible) {
  $dot=$script:ui.CompactTaskPulse
  $opacity=[Windows.UIElement]::OpacityProperty
  Set-AnimatedValue $dot $opacity 1
  if(!$Visible -or ![Windows.SystemParameters]::ClientAreaAnimation){return}
  $pulse=[Windows.Media.Animation.DoubleAnimation]::new(1,0.22,[Windows.Duration]::new([TimeSpan]::FromMilliseconds(520)))
  $pulse.AutoReverse=$true;$pulse.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
  $dot.BeginAnimation($opacity,$pulse)
}

function Set-SkinCompactPage([string]$Page,[bool]$Animate) {
  $pages=@{water=$script:ui.WaterCountdown;task=$script:ui.CompactTask;notice=$script:ui.CompactNotice}
  $previous=$script:skinCompactPage
  $incoming=$pages[$Page];$outgoing=$pages[$previous]
  $script:skinCompactPage=$Page
  if($Page-ne 'notice'){
    $seconds=if($Page-eq 'water'){5}else{10}
    $script:skinCompactTimer.Interval=[TimeSpan]::FromSeconds($seconds)
  }
  Set-SkinStepPulse ($Page-eq 'task')
  $opacity=[Windows.UIElement]::OpacityProperty;$y=[Windows.Media.TranslateTransform]::YProperty
  foreach($layer in $pages.Values){
    Set-AnimatedValue $layer $opacity ([double]($layer-eq $incoming))
    Set-AnimatedValue $layer.RenderTransform $y 0
  }
  if($Animate -and [Windows.SystemParameters]::ClientAreaAnimation){
    Set-AnimatedValue $incoming $opacity 0
    Set-AnimatedValue $incoming.RenderTransform $y 10
    Animate-Value $incoming $opacity 1 220
    Animate-Value $incoming.RenderTransform $y 0 220
    if($outgoing -and $outgoing-ne $incoming){
      Set-AnimatedValue $outgoing $opacity 1
      Animate-Value $outgoing $opacity 0 170
      Animate-Value $outgoing.RenderTransform $y -10 220
    }
  }
  $script:ui.WaterBubble.ToolTip=switch($Page){
    'task' {$script:ui.CompactTaskTitle.Text+[Environment]::NewLine+$script:ui.CompactTaskStep.Text}
    'notice' {$script:skinCompactNotice.title+' · '+$script:skinCompactNotice.message}
    default {'点击查看上班状态'}
  }
}

function Set-SkinCompactTaskText($Task,[bool]$Animate) {
  $title=[string]$Task.title;$step=if($Task.step){[string]$Task.step}else{'正在执行'}
  if($script:ui.CompactTaskTitle.Text-cne $title){$script:ui.CompactTaskTitle.Text=$title}
  $line=$script:ui.CompactTaskStep
  if($line.Text-cne $step){
    $line.Text=$step
    $opacity=[Windows.UIElement]::OpacityProperty;$y=[Windows.Media.TranslateTransform]::YProperty
    Set-AnimatedValue $line $opacity 1
    Set-AnimatedValue $line.RenderTransform $y 0
    if($Animate -and [Windows.SystemParameters]::ClientAreaAnimation){
      Set-AnimatedValue $line $opacity 0
      Set-AnimatedValue $line.RenderTransform $y 12
      Animate-Value $line $opacity 1 310
      Animate-Value $line.RenderTransform $y 0 310
    }
  }
  $script:ui.WaterBubble.ToolTip=$title+[Environment]::NewLine+$step
}

function Select-SkinCompactSlot($Tasks,[bool]$Water) {
  $animate=[bool]$script:skinCompactPage
  if($script:skinCompactPage-ne 'task'){$script:skinPlayedTasks.Clear()}
  $next=$Tasks|Where-Object{!$script:skinPlayedTasks.Contains($_.id)}|Select-Object -First 1
  if(!$next -and !$Water -and $Tasks.Count){$script:skinPlayedTasks.Clear();$next=$Tasks[0]}
  if(!$next){
    $script:skinCompactTaskId=$null
    if($script:skinCompactPage-ne 'water'){Set-SkinCompactPage 'water' $animate}
    return
  }
  $script:skinCompactTaskId=$next.id
  [void]$script:skinPlayedTasks.Add($next.id)
  Set-SkinCompactTaskText $next $false
  Set-SkinCompactPage 'task' $animate
  Send-SkinAction 'activity.focus' @{id=$next.id}
}

function Update-SkinCompactBubble([switch]$Advance) {
  if(!$script:ui.WaterBubble){return}
  $tasks=@($script:skinSnapshot.tasks|Where-Object{$_.id-is [string] -and $_.title-is [string]})
  $water=$script:skinSnapshot.workday.waterStartedAt -gt 0
  $show=($water -or $tasks.Count -or $script:skinCompactNotice) -and !$script:skinHidden -and $script:window.IsVisible -and $script:collapsed -and !$script:settingsBubblePreview -and !($script:closeTimer -and $script:closeTimer.IsEnabled)
  if(!$show){
    if($script:skinCompactPage-eq 'task'){Set-SkinStepPulse $false}
    $script:skinCompactTimer.Stop();$script:skinCompactPage=''
    $script:ui.WaterBubble.Visibility=[Windows.Visibility]::Collapsed
    return
  }
  $script:ui.WaterBubble.Visibility=[Windows.Visibility]::Visible
  if($script:skinCompactNotice){
    $script:skinCompactTimer.Stop()
    if($script:skinCompactPage-ne 'notice'){Set-SkinCompactPage 'notice' ([bool]$script:skinCompactPage)}
    return
  }
  $current=$tasks|Where-Object{$_.id-ceq $script:skinCompactTaskId}|Select-Object -First 1
  $cycle=$tasks.Count-gt 0 -and ($water -or $tasks.Count-gt 1)
  $lostTask=$script:skinCompactPage-eq 'task' -and !$current
  if($Advance -or $lostTask -or $script:skinCompactPage-in @('','notice') -or ($script:skinCompactPage-eq 'water' -and !$script:skinCompactTimer.IsEnabled -and $tasks.Count)){
    Select-SkinCompactSlot $tasks $water
    if($lostTask){$script:skinCompactTimer.Stop()}
  }elseif($current -and $script:skinCompactPage-eq 'task'){Set-SkinCompactTaskText $current $true}
  if($cycle){if(!$script:skinCompactTimer.IsEnabled){$script:skinCompactTimer.Start()}}else{$script:skinCompactTimer.Stop()}
}

function Update-SkinWorkday {
  $state=$script:skinSnapshot.workday
  if(!$state){$script:ui.WorkdayCountdown.Text='连接中';$script:ui.WorkdayPrimary.IsEnabled=$false;$script:ui.WorkdayDrink.IsEnabled=$false;Update-SkinCompactBubble;return}
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
  $phase=if(!$current){'上班'}elseif(!$running){'下班'}elseif($elapsed-lt $workMs){'下班'}else{'加班'}
  $remaining=if($running){[Math]::Max(0,([double]$(if($elapsed-lt $workMs){$workMs}else{$totalMs}))-$elapsed)}else{0}
  $minutes=[int][Math]::Ceiling($remaining/60000)
  $script:ui.WorkdayPhase.Text=$phase
  $script:ui.WorkdayCountdown.FontSize=if($running){24}else{16}
  $script:ui.WorkdayCountdown.Text=if($running){'{0:00}:{1:00}'-f [int][Math]::Floor($minutes/60),($minutes%60)}elseif($current){'已结束'}else{'未开始'}
  $water=[int][Math]::Max(0,[Math]::Ceiling(([double]$settings.waterMinutes*60000-($now-[double]$state.waterStartedAt))/1000))
  $countdown='{0:00}:{1:00}'-f [int][Math]::Floor($water/60),($water%60)
  $script:ui.WorkdayWater.Text=$countdown
  $script:ui.WaterCountdown.Text='喝水  '+$countdown
  $script:ui.WorkdayPrimary.Content=if($running){'下班'}else{'上班'}
  Update-SkinCompactBubble
}

function Receive-SkinSnapshot($Snapshot) {
  $script:skinSnapshot=$Snapshot;$script:status=$Snapshot.quota
  if($script:skinHidden-eq [bool]$Snapshot.enabled){Set-SkinWidgetVisibility ([bool]$Snapshot.enabled)}
  if(!$script:skinHidden){Update-SkinWorkday}
  Update-Quota
}

function Tick-SkinManaged {
  if([GptSkinPipe]::Closed){$script:skinOwnerClosed=$true;$script:window.Close();return}
  $line=$null
  $pendingSnapshot=$null
  for($index=0;$index-lt 64 -and [GptSkinPipe]::TryRead([ref]$line);$index++){
    try {
      $message=$line|ConvertFrom-Json
      if($message.v-ne 1){continue}
      # Collapse adjacent snapshots while retaining ordering around reminders
      # and completions. A burst should paint its latest state only once.
      if($message.type-eq 'snapshot'){$pendingSnapshot=$message;continue}
      if($pendingSnapshot){Receive-SkinSnapshot $pendingSnapshot;$pendingSnapshot=$null}
      switch([string]$message.type){
        'reminder' {
          if($message.kind-notin @('workday','water','completion') -or $message.title-isnot [string] -or $message.message-isnot [string]){continue}
          if($message.kind-eq 'completion' -and !$script:completionNotificationsEnabled){continue}
          if($message.kind-eq 'workday'){
            [GptSkinNotification]::Show($script:widgetHandle,[Drawing.SystemIcons]::Information.Handle,$message.title,$message.message)|Out-Null
            $script:skinNotificationTimer.Stop();$script:skinNotificationTimer.Start()
            Play-WidgetPressSound
          }
          if($script:skinReminders.Count-lt 4){$script:skinReminders.Enqueue($message)}
        }
        'error' {$script:ui.Status.Text=[string]$message.message;$script:ui.WorkdayCountdown.ToolTip=[string]$message.message}
      }
    }catch{$script:ui.Status.Text='共享状态暂不可用'}
    $line=$null
  }
  if($pendingSnapshot){try{Receive-SkinSnapshot $pendingSnapshot}catch{$script:ui.Status.Text='共享状态暂不可用'}}
  $second=[long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000)
  if(!$script:skinHidden -and $second-ne $script:skinWorkdaySecond){$script:skinWorkdaySecond=$second;Update-SkinWorkday}
}

function Tick-SkinReminder {
  if(!$script:skinReminders.Count -or $script:skinCompactNotice -or !$script:window.IsVisible -or !$script:collapsed -or $script:drag -or $script:context.IsOpen -or $script:settingsSizePreview -or ($script:closeTimer -and $script:closeTimer.IsEnabled) -or (Test-WidgetUpdateEditor)){return}
  do{
    if(!$script:skinReminders.Count){return}
    $next=$script:skinReminders.Dequeue()
  }while($next.kind-eq 'completion' -and !$script:completionNotificationsEnabled)
  if($next.kind-eq 'workday'){
    $script:ui.QuoteText.Text=$next.title+[Environment]::NewLine+$next.message;Fit-QuoteText
    Open-WidgetBubble 'reminder'
  }else{
    $script:skinCompactNotice=$next
    $script:ui.CompactNoticeMark.Text=if($next.kind-eq 'completion'){'✓ '}else{''}
    $script:ui.CompactNoticeTitle.Text=$next.title;$script:ui.CompactNoticePreview.Text=$next.message
    Update-SkinCompactBubble
    $script:skinNoticeTimer.Start();Play-WidgetPressSound
  }
  $script:skinReminderAnimating=$true;$script:skinReminderDown=$true
  Animate-Press $true;$script:skinBounceTimer.Stop();$script:skinBounceTimer.Start()
}

function Stop-SkinManagedRuntime {
  foreach($timer in @($script:skinNotificationTimer,$script:skinBounceTimer,$script:skinCompactTimer,$script:skinNoticeTimer)){if($timer){$timer.Stop()}}
  if('GptSkinNotification'-as [type]){[GptSkinNotification]::Hide()}
}
