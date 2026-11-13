$script:widgetMusic=$null
$script:musicColorEnabled=$false
$script:musicLastError=$null
$script:widgetMeditation=$null
$script:meditationEditor=$null
function Initialize-WidgetMusicTypes {
  if('GptMusicVisual' -as [type]){return}
  Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml,System.Windows.Forms,System.Drawing
  $references=@('System.dll','System.Core.dll','System.Xaml.dll','System.Windows.Forms.dll','System.Drawing.dll',[Windows.Window].Assembly.Location,[Windows.Media.Brush].Assembly.Location,[Windows.Point].Assembly.Location)
  Add-Type -Path @((Join-Path $script:appDir 'runtime/music-audio.cs'),(Join-Path $script:appDir 'runtime/music-visual.cs')) -ReferencedAssemblies $references
}
function Test-WidgetMusicActive {
  # A visual-layer failure stops the C# object internally. Reconcile the
  # PowerShell/menu state on the next check instead of leaving a stale
  # "enabled" menu item and a half-restored layout.
  if($script:widgetMusic -and !$script:widgetMusic.Enabled){try{Stop-WidgetMusic}catch{}}
  return [bool]($script:widgetMusic -and $script:widgetMusic.Enabled)
}
function Set-WidgetMusicPickupColor {
  if(!(Test-WidgetMusicActive)){return}
  $chance=[Math]::Min(100.0,[Math]::Max(0.0,2.0*$script:colorChance))/100.0
  $script:musicColorEnabled=($script:colorMode-ne 'original' -and $chance-gt 0 -and (Get-WidgetColorRoll)-lt $chance)
  $script:widgetMusic.ColorEnabled=$script:musicColorEnabled
  $script:widgetMusic.Redraw()
}
function Stop-WidgetMusic([switch]$KeepPosition) {
  if($script:widgetMusic){
    $state=$script:widgetMusic;$script:widgetMusic=$null
    try{$state.Stop([bool]$KeepPosition)}finally{if($state.Error){$script:musicLastError=$state.Error}}
  }
  $script:musicColorEnabled=$false
  $script:lastPosition=$null
  if($script:widgetColors){Update-WidgetColorScene}
  if($script:settingsMenuUi -and $script:settingsMenuUi.MusicEnabled){$script:settingsMenuUi.MusicEnabled.IsChecked=$false}
  if($script:hostEventTimer -and !$script:runtimeClosed){$script:hostEventTimer.Start()}
}
function Set-WidgetMusicEnabled([bool]$Enabled) {
  if(!$Enabled){Stop-WidgetMusic;return}
  if(Test-WidgetMusicActive){return}
  if(!$script:window.IsVisible){throw '请先显示挂件再开启音乐律动。'}
  try{
    Stop-WidgetMeditation
    Hide-Quota
    Initialize-WidgetMusicTypes
    $colors=[Windows.Media.Color[]]@(Get-WidgetColorPalette 'rainbow'|ForEach-Object{[Windows.Media.ColorConverter]::ConvertFromString($_)})
    $move=[Delegate]::CreateDelegate([Action[int,int]],$script:hostFollower,'SetTemporaryOffset')
    $normal=New-Object GptWidgetNative+Rect;[GptWidgetNative]::GetWindowRect($script:widgetHandle,[ref]$normal)|Out-Null
    $script:musicLastError=$null;$script:musicColorEnabled=$false
    $script:widgetMusic=[GptMusicVisual]::new($script:window,$script:ui.Girl,$script:ui.Bubble,$move,$colors,($script:characterId-eq 'gpt-dragon'))
    $script:widgetMusic.FollowLamp=[Delegate]::CreateDelegate([Action[IntPtr,int,int,int]],$script:hostFollower,'SetCompanion')
    $script:widgetMusic.HostFrame=[Delegate]::CreateDelegate([Func[int[]]],$script:hostFollower,'GetFrame')
    Update-WidgetMusicPlacement (Get-WidgetPlacementFrame) (Get-WidgetPlacementDpi) $normal.Left $normal.Top $true
    Update-WidgetColorScene
    $script:lastPosition=$null;Tick-Widget
    if($script:settingsMenuUi.MusicEnabled){$script:settingsMenuUi.MusicEnabled.IsChecked=$true}
  }catch{
    $script:musicLastError=$_.Exception.Message;Stop-WidgetMusic
    [Windows.MessageBox]::Show(('音乐律动暂时无法启动：'+$script:musicLastError),'GPT 娘')|Out-Null
  }
}

function Read-WidgetMeditationTea {
  # Bundled SVG paths map directly to WPF geometry. The steam path is animated separately.
  $asset=Join-Path $script:appDir 'assets/meditation-tea.svg'
  $document=[Xml.XmlDocument]::new()
  $document.XmlResolver=$null
  $xmlSettings=[Xml.XmlReaderSettings]::new()
  $xmlSettings.DtdProcessing='Prohibit'
  $reader=[Xml.XmlReader]::Create($asset,$xmlSettings)
  try{$document.Load($reader)}finally{$reader.Dispose()}
  $brushes=[Windows.Media.BrushConverter]::new()
  $cup=[Windows.Media.DrawingGroup]::new()
  foreach($path in $document.DocumentElement.ChildNodes){
    if($path.LocalName-ne 'path'){continue}
    $shape=[Windows.Media.Geometry]::Parse($path.GetAttribute('d'))
    $stroke=$brushes.ConvertFromString($path.GetAttribute('stroke'))
    if($path.GetAttribute('id')-eq 'steam'){$steam=$shape;$steamBrush=$stroke;continue}
    $fill=if($path.GetAttribute('fill')-ne 'none'){$brushes.ConvertFromString($path.GetAttribute('fill'))}else{$null}
    $pen=[Windows.Media.Pen]::new($stroke,[double]$path.GetAttribute('stroke-width'))
    if($path.GetAttribute('stroke-linecap')-eq 'round'){$pen.StartLineCap='Round';$pen.EndLineCap='Round'}
    $cup.Children.Add([Windows.Media.GeometryDrawing]::new($fill,$pen,$shape))
  }
  $cup.Freeze();$steam.Freeze();$steamBrush.Freeze()
  return @{cup=$cup;steam=$steam;steamBrush=$steamBrush}
}

function Stop-WidgetMeditation {
  if(!$script:widgetMeditation){return}
  $state=$script:widgetMeditation;$script:widgetMeditation=$null
  if($script:meditationEditor){$script:meditationEditor.Close()}
  $state.Dispose()
  $script:ui.CompactMeditation.DataContext=$null
  if($script:settingsMenuUi.Meditation){$script:settingsMenuUi.Meditation.IsChecked=$false}
  if(!$script:runtimeClosed){Update-SkinCompactBubble}
}

function Read-WidgetClosedEyes([string]$Id) {
  if($Id-eq 'gpt-dragon'){
    Read-WidgetCharacterImage (Join-Path $script:appDir 'assets/gpt-dragon-niang-bust-eyes-closed.png')
  }
}

function Set-WidgetMeditationEnabled([bool]$Enabled) {
  if(!$Enabled){Stop-WidgetMeditation;return}
  if(!$SkinManaged -or $script:widgetMeditation -or !$script:window.IsVisible){return}
  try{
    Initialize-WidgetMusicTypes
    $tea=Read-WidgetMeditationTea
    $closedEyes=Read-WidgetClosedEyes $script:characterId
    if(Test-WidgetMusicActive){Stop-WidgetMusic}
    Hide-Quota
    Stop-SkinReminderAnimation
    $script:widgetMeditation=[GptMeditationVisual]::new($script:window,$script:ui.Girl,$script:widgetColors.halo,$script:widgetColors.tint,$tea.cup,$tea.steam,$tea.steamBrush,$closedEyes)
    $script:ui.CompactMeditation.DataContext=$script:widgetMeditation
    $script:widgetMeditation.Recognize()
    Update-SkinCompactBubble
  }catch{
    Stop-WidgetMeditation
    [Windows.MessageBox]::Show(('入定模式暂时无法启动：'+$_.Exception.Message),'龙娘')|Out-Null
  }finally{$script:settingsMenuUi.Meditation.IsChecked=[bool]$script:widgetMeditation}
}

function Open-WidgetMeditationEditor($Anchor) {
  if(!$script:widgetMeditation){return}
  if($script:meditationEditor){$script:meditationEditor.Activate()|Out-Null;return}
  $editor=[Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="入定设置" Width="250" SizeToContent="Height" WindowStyle="ToolWindow" ResizeMode="NoResize" ShowInTaskbar="False"
        FontFamily="Microsoft YaHei UI" FontSize="13" Background="#FAF8FD" Foreground="#513968">
  <StackPanel Margin="14">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="32"/><ColumnDefinition Width="54"/><ColumnDefinition Width="32"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="32"/><RowDefinition Height="32"/><RowDefinition Height="32"/></Grid.RowDefinitions>
      <TextBlock Text="拍号" VerticalAlignment="Center"/>
      <ComboBox x:Name="Meter" Grid.Column="1" Grid.ColumnSpan="3" VerticalAlignment="Center" AutomationProperties.Name="拍号">
        <ComboBoxItem Content="2/4"/><ComboBoxItem Content="3/4"/><ComboBoxItem Content="4/4"/><ComboBoxItem Content="6/8"/>
      </ComboBox>
      <TextBlock Grid.Row="1" Text="BPM" VerticalAlignment="Center"/>
      <Button x:Name="BpmMinus" Grid.Row="1" Grid.Column="1" Content="−" Margin="0,3" AutomationProperties.Name="减少 BPM"/>
      <TextBox x:Name="Bpm" Grid.Row="1" Grid.Column="2" Margin="4,3" VerticalContentAlignment="Center" TextAlignment="Center" MaxLength="5" AutomationProperties.Name="BPM"/>
      <Button x:Name="BpmPlus" Grid.Row="1" Grid.Column="3" Content="+" Margin="0,3" AutomationProperties.Name="增加 BPM"/>
      <TextBlock Grid.Row="2" Text="每轮拍数" VerticalAlignment="Center"/>
      <Button x:Name="BeatsMinus" Grid.Row="2" Grid.Column="1" Content="−" Margin="0,3" AutomationProperties.Name="减少每轮拍数"/>
      <TextBox x:Name="Beats" Grid.Row="2" Grid.Column="2" Margin="4,3" VerticalContentAlignment="Center" TextAlignment="Center" MaxLength="2" AutomationProperties.Name="每轮拍数"/>
      <Button x:Name="BeatsPlus" Grid.Row="2" Grid.Column="3" Content="+" Margin="0,3" AutomationProperties.Name="增加每轮拍数"/>
    </Grid>
    <TextBlock x:Name="Feedback" Foreground="#865362" TextWrapping="Wrap"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Cancel" Content="取消" IsCancel="True" Padding="10,3" Margin="0,0,8,0"/>
      <Button x:Name="Apply" Content="应用" IsDefault="True" Padding="10,3"/>
    </StackPanel>
  </StackPanel>
</Window>
'@)
  $script:meditationEditor=$editor
  $editor.Owner=$script:window
  $culture=[Globalization.CultureInfo]::InvariantCulture
  $editor.FindName('Bpm').Text=$script:widgetMeditation.Bpm.ToString('0.#',$culture)
  $editor.FindName('Beats').Text=[string]$script:widgetMeditation.Beats
  $meter=$editor.FindName('Meter')
  $meter.SelectedItem=$meter.Items|Where-Object{$_.Content-eq $script:widgetMeditation.Meter}|Select-Object -First 1
  foreach($field in @(@{name='Bpm';min=30;max=240},@{name='Beats';min=2;max=32})){
    foreach($step in @(@{suffix='Minus';value=-1},@{suffix='Plus';value=1})){
      $button=$editor.FindName($field.name+$step.suffix)
      $button.Tag=@{field=$field.name;min=$field.min;max=$field.max;step=$step.value}
      $button.Add_Click({param($sender,$event)
        $setting=$sender.Tag;$panel=$script:meditationEditor;$box=$panel.FindName($setting.field)
        $current=0.0;$format=[Globalization.CultureInfo]::InvariantCulture
        if(![double]::TryParse($box.Text,[Globalization.NumberStyles]::AllowDecimalPoint,$format,[ref]$current)){
          $current=if($setting.field-eq 'Bpm'){$script:widgetMeditation.Bpm}else{$script:widgetMeditation.Beats}
        }
        if($setting.field-eq 'Beats'){$current=[Math]::Round($current)}
        $box.Text=[Math]::Max($setting.min,[Math]::Min($setting.max,$current+$setting.step)).ToString('0.#',$format)
        $panel.FindName('Feedback').Text=''
      })
    }
  }
  $editor.FindName('Apply').Add_Click({
    $panel=$script:meditationEditor;$bpm=0.0;$beats=0
    $validBpm=[double]::TryParse($panel.FindName('Bpm').Text,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$bpm)
    $validBeats=[int]::TryParse($panel.FindName('Beats').Text,[ref]$beats)
    if(!$validBpm -or $bpm-lt 30 -or $bpm-gt 240 -or !$validBeats -or $beats-lt 2 -or $beats-gt 32){
      $panel.FindName('Feedback').Text='请输入 30–240 BPM 和 2–32 拍。';return
    }
    $script:widgetMeditation.Apply($bpm,[string]$panel.FindName('Meter').SelectedItem.Content,$beats)
    $panel.Close()
  })
  $editor.FindName('Cancel').Add_Click({$script:meditationEditor.Close()})
  $editor.Add_Closed({$script:meditationEditor=$null})
  $origin=$Anchor.PointToScreen([Windows.Point]::new(0,0))
  $below=$Anchor.PointToScreen([Windows.Point]::new(0,$Anchor.ActualHeight))
  $area=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int]$origin.X,[int]$origin.Y)).WorkingArea
  $editor.Show()
  $handle=[Windows.Interop.WindowInteropHelper]::new($editor).Handle
  $rect=[GptWidgetNative]::Frame($handle)
  $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top
  $x=[int][Math]::Max($area.Left,[Math]::Min($area.Right-$width,$origin.X))
  $y=if($below.Y+8+$height-le $area.Bottom){$below.Y+8}else{[Math]::Max($area.Top,$origin.Y-8-$height)}
  [GptWidgetNative]::SetWindowPos($handle,[IntPtr]::Zero,$x,[int]$y,0,0,0x15)|Out-Null
  $focus=$editor.FindName($(if($Anchor-eq $script:ui.MeditationCycle){'Beats'}else{'Bpm'}))
  $focus.Focus()|Out-Null;$focus.SelectAll()
}

function Update-WidgetMusicPlacement($Frame,[double]$Dpi,[double]$X,[double]$Y,[bool]$Visible) {
  if(!(Test-WidgetMusicActive)){return}
  try{
    $blocked=[bool]($script:settingsSizePreview -or ($script:characterGallery -and $script:characterGallery.IsVisible) -or ($script:quoteEditor -and $script:quoteEditor.IsVisible))
    $script:widgetMusic.Configure($script:widgetHandle,$script:hostHandle,$script:followHost,$Visible,$blocked,$script:desktopTopmost,$X,$Y,$Frame.Left,$Frame.Bottom,$Dpi)
  }catch{
    # A music placement failure must not truncate the rest of Tick-Widget.
    $script:musicLastError=$_.Exception.Message
    try{Stop-WidgetMusic}catch{}
    try{[IO.File]::WriteAllText((Join-Path $script:dataDir 'music-error.txt'),$script:musicLastError,[Text.UTF8Encoding]::new($false))}catch{}
  }
}
function Update-WidgetMusicVisibility([bool]$Visible,[bool]$Blocked=$false) {
  if(!$script:widgetMusic){return}
  try{$script:widgetMusic.SetVisibility($Visible,$Blocked)}
  catch{
    $script:musicLastError=$_.Exception.Message
    try{Stop-WidgetMusic}catch{}
    try{[IO.File]::WriteAllText((Join-Path $script:dataDir 'music-error.txt'),$script:musicLastError,[Text.UTF8Encoding]::new($false))}catch{}
  }
}
function Get-WidgetMusicStatus {
  if(!(Test-WidgetMusicActive)){return @{enabled=$false;color=$script:musicColorEnabled;error=if($script:widgetMusic -and $script:widgetMusic.Error){$script:widgetMusic.Error}else{$script:musicLastError}}}
  $a=$script:widgetMusic.Audio;$m=$script:widgetMusic.Motion
  return @{enabled=$true;color=$script:musicColorEnabled;paused=$script:widgetMusic.Paused;running=[bool]($a -and $a.Running);source=if($a){$a.Source}else{'system-playback'};sourceProcessId=if($a){$a.SourceProcessId}else{0};captureReadyMs=if($a){$a.CaptureReadyMs}else{0};firstPacketMs=if($a){$a.FirstPacketMs}else{0};
    beats=if($a){$a.BeatSequence}else{0};onsets=if($a){$a.Sequence}else{0};rhythmLocked=[bool]($a -and $a.RhythmLocked);bpm=if($a){$a.Bpm}else{0};confidence=if($a){$a.Confidence}else{0};
    tracking=if(!$a -or !$a.RhythmLocked){'acquiring'}elseif($a.BassCycle){'bass-cycle'}else{'onsets'};
    nextBeatAtMs=if($a){$a.NextBeatAtMs}else{0};periodMs=if($a){$a.PeriodMs}else{0};audioLagMs=if($a){$a.AudioLagMs}else{0};
    strength=if($a){$a.Strength}else{0};sampleRate=if($a){$a.SampleRate}else{0};channels=if($a){$a.Channels}else{0};
    level=if($a){$a.Level}else{0};lowLevel=if($a){$a.LowLevel}else{0};drive=if($a){$a.Drive}else{0};error=if($script:widgetMusic.Error){$script:widgetMusic.Error}elseif($a){$a.Error}else{$null};
    phase=if($m){$m.Phase}else{-1};held=[bool]($m -and $m.Held);velocityX=if($m){$m.Vx}else{0};velocityY=if($m){$m.Vy}else{0};
    releaseVelocityX=if($m -and !$m.Held){$m.ThrowX}else{0};releaseVelocityY=if($m -and !$m.Held){$m.ThrowY}else{0};releaseIdleMs=if($m){$m.ReleaseIdleMs}else{0};
    impacts=if($m){$m.Impacts}else{0};compression=if($m){$m.Bend}else{0};x=if($m){$m.X}else{0};y=if($m){$m.Y}else{0};
    lamp=$script:widgetMusic.LampHandle.ToInt64()}
}
