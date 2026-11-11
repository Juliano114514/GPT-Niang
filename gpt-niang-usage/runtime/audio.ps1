# Preloaded, volume-scaled PCM; native playback stays on one audio worker.
if ($null -eq (Get-Variable -Name gptNiangAudio -Scope Script -ErrorAction SilentlyContinue)) {
    $script:gptNiangAudio = $null
}

function Get-WidgetAudioEnabled {
    $setting = Get-Variable -Name soundOn -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $setting) { return $true }
    return ($setting.Value -ne $false)
}

function Get-WidgetAudioVolume {
    $setting = Get-Variable -Name soundVolume -Scope Script -ErrorAction SilentlyContinue
    $value = 0.9
    if ($null -ne $setting) {
        try { $value = [double]$setting.Value } catch { $value = 0.9 }
    }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { $value = 0.9 }
    return [Math]::Min(1.0, [Math]::Max(0.0, $value))
}

if(!('GptClickAudioQueue' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class GptNiangPcm {
 public static byte[] Scale(byte[] source,int offset,int length,double volume){
  if(volume==1)return source;
  var output=(byte[])source.Clone();
  for(int i=offset;i<offset+length;i+=2){
   int value=(short)(source[i]|(source[i+1]<<8));
   int scaled=(int)Math.Round(value*volume,MidpointRounding.AwayFromZero);
   short sample=(short)Math.Max(-32768,Math.Min(32767,scaled));
   output[i]=(byte)(sample&255);output[i+1]=(byte)((sample>>8)&255);
  }
  return output;
 }
}
public sealed class GptClickAudioStart {
 private long startedAt;
 private volatile bool resolved;
 internal void Complete(bool started){
  if(started)startedAt=Stopwatch.GetTimestamp();
  resolved=true;
 }
 public double SecondsUntil(double duration){
  if(!resolved)return double.PositiveInfinity;
  if(startedAt==0)return 0;
  double elapsed=(Stopwatch.GetTimestamp()-startedAt)/(double)Stopwatch.Frequency;
  return Math.Max(0,duration-elapsed);
 }
}
sealed class GptClickWaveOutput : IDisposable {
 [StructLayout(LayoutKind.Sequential,Pack=2)]
 struct WaveFormat {
  public ushort Tag,Channels;
  public uint Rate,BytesPerSecond;
  public ushort Align,Bits,ExtraSize;
 }
 [StructLayout(LayoutKind.Sequential)]
 struct WaveHeader {
  public IntPtr Data;
  public uint Length,Recorded;
  public IntPtr User;
  public uint Flags,Loops;
  public IntPtr Next,Reserved;
 }
 [DllImport("winmm.dll")] static extern uint waveOutOpen(out IntPtr device,uint id,ref WaveFormat format,IntPtr callback,IntPtr instance,uint flags);
 [DllImport("winmm.dll")] static extern uint waveOutPrepareHeader(IntPtr device,IntPtr header,uint size);
 [DllImport("winmm.dll")] static extern uint waveOutWrite(IntPtr device,IntPtr header,uint size);
 [DllImport("winmm.dll")] static extern uint waveOutReset(IntPtr device);
 [DllImport("winmm.dll")] static extern uint waveOutUnprepareHeader(IntPtr device,IntPtr header,uint size);
 [DllImport("winmm.dll")] static extern uint waveOutClose(IntPtr device);
 static readonly uint HeaderSize=(uint)Marshal.SizeOf(typeof(WaveHeader));
 static readonly int FlagsOffset=Marshal.OffsetOf(typeof(WaveHeader),"Flags").ToInt32();
 IntPtr device,header;
 WaveFormat currentFormat;
 GCHandle buffer;
 bool prepared,submitted;
 long deadline;
 bool Done { get { return !submitted || (Marshal.ReadInt32(header,FlagsOffset)&1)!=0; } }
 static void Check(uint result,string operation){
  if(result!=0)throw new InvalidOperationException(operation+" failed ("+result+")");
 }
 static WaveFormat ReadFormat(byte[] wave,out int dataOffset,out uint dataLength){
  var format=new WaveFormat();
  dataOffset=0;dataLength=0;
  for(int offset=12;offset<=wave.Length-8;){
   int tag=BitConverter.ToInt32(wave,offset);
   uint length=BitConverter.ToUInt32(wave,offset+4);
   int body=offset+8;
   if((long)length+(length&1)>wave.Length-body)break;
   if(tag==0x20746d66 && length>=16){
    format.Tag=BitConverter.ToUInt16(wave,body);
    format.Channels=BitConverter.ToUInt16(wave,body+2);
    format.Rate=BitConverter.ToUInt32(wave,body+4);
    format.BytesPerSecond=BitConverter.ToUInt32(wave,body+8);
    format.Align=BitConverter.ToUInt16(wave,body+12);
    format.Bits=BitConverter.ToUInt16(wave,body+14);
   }else if(tag==0x61746164){dataOffset=body;dataLength=length;}
   offset=body+(int)length+(int)(length&1);
  }
  if(format.Tag!=1 || format.BytesPerSecond==0 || dataLength==0)throw new InvalidOperationException("Invalid PCM clip");
  return format;
 }
 void EnsureDevice(WaveFormat format){
  if(device!=IntPtr.Zero && currentFormat.Rate==format.Rate && currentFormat.Channels==format.Channels)return;
  CloseDevice();
  Check(waveOutOpen(out device,uint.MaxValue,ref format,IntPtr.Zero,IntPtr.Zero,0),"Opening audio output");
  currentFormat=format;
 }
 public void WarmUp(byte[] wave){
  int offset;uint length;
  var format=ReadFormat(wave,out offset,out length);
  EnsureDevice(format);
  // A silent buffer starts the device before the first audible click.
  uint frames=format.Rate*80/1000;
  var silence=new byte[frames*format.Align];
  WriteSamples(silence,0,(uint)silence.Length,format);
 }
 public bool Play(byte[] wave,bool afterPrevious,Func<bool> interrupted){
  if(afterPrevious){
   while(!Done){
    if(interrupted())return false;
    if(Stopwatch.GetTimestamp()>deadline)throw new TimeoutException("Audio playback did not finish");
    Thread.Sleep(5);
   }
   if(interrupted())return false;
  }
  Stop();
  int dataOffset;uint dataLength;
  var format=ReadFormat(wave,out dataOffset,out dataLength);
  EnsureDevice(format);
  WriteSamples(wave,dataOffset,dataLength,format);
  return true;
 }
 void WriteSamples(byte[] wave,int dataOffset,uint dataLength,WaveFormat format){
  if(header==IntPtr.Zero)header=Marshal.AllocHGlobal((int)HeaderSize);
  buffer=GCHandle.Alloc(wave,GCHandleType.Pinned);
  var next=new WaveHeader{Data=IntPtr.Add(buffer.AddrOfPinnedObject(),dataOffset),Length=dataLength};
  Marshal.StructureToPtr(next,header,false);
  Check(waveOutPrepareHeader(device,header,HeaderSize),"Preparing audio");
  prepared=true;
  Check(waveOutWrite(device,header,HeaderSize),"Writing audio");
  submitted=true;
  deadline=Stopwatch.GetTimestamp()+(long)(Stopwatch.Frequency*(1.0+dataLength/(double)format.BytesPerSecond));
 }
 public void Stop(){
  if(!Done)Check(waveOutReset(device),"Stopping audio");
  if(prepared){
   Check(waveOutUnprepareHeader(device,header,HeaderSize),"Releasing audio");
   prepared=false;
  }
  submitted=false;
  if(buffer.IsAllocated)buffer.Free();
 }
 public void CloseDevice(){
  if(device==IntPtr.Zero)return;
  Check(waveOutClose(device),"Closing audio output");
  device=IntPtr.Zero;
 }
 public void Dispose(){
  Stop();
  CloseDevice();
  if(header!=IntPtr.Zero){Marshal.FreeHGlobal(header);header=IntPtr.Zero;}
 }
}
public sealed class GptClickAudioQueue : IDisposable {
 private sealed class Command {
  public readonly byte[] Wave;
  public readonly GptClickAudioStart Start;
  public readonly bool AfterPrevious;
  public readonly bool WarmUp;
  public Command(byte[] wave,GptClickAudioStart start,bool afterPrevious=false,bool warmUp=false){
   Wave=wave;Start=start;AfterPrevious=afterPrevious;WarmUp=warmUp;
  }
 }
 // One pending command: a blocked driver must not accumulate stale clicks.
 private readonly BlockingCollection<Command> queue=new BlockingCollection<Command>(1);
 private readonly Thread worker;
 private readonly Func<IntPtr,uint,bool> play;
 private readonly GptClickWaveOutput output;
 private static readonly object gate=new object();
 private static GptClickAudioQueue owner;
 private GCHandle current;
 private bool closed;
 private volatile string error;
 public string Error { get { return error; } }
 public bool IsRunning { get { return worker.IsAlive; } }
 public GptClickAudioQueue() : this(null) {}
 public GptClickAudioQueue(Func<IntPtr,uint,bool> playback){
  play=playback;
  if(playback==null)output=new GptClickWaveOutput();
  worker=new Thread(Loop);worker.IsBackground=true;worker.Name="gpt-click-audio";worker.Start();
 }
 private static void Reset(){
  if(owner==null)return;
  // Keep asynchronous PCM memory pinned until native playback really stops.
  if(!owner.play(IntPtr.Zero,0))throw new InvalidOperationException("Audio stop failed");
  if(owner.current.IsAllocated)owner.current.Free();
  owner=null;
 }
 private bool Run(byte[] wave){
  lock(gate){
   for(int attempt=0;attempt<2;attempt++){
    try{
     Reset();
     if(wave==null){error=null;return true;}
     current=GCHandle.Alloc(wave,GCHandleType.Pinned);owner=this;
     if(play(current.AddrOfPinnedObject(),0x0007)){error=null;return true;}
     error="Audio playback failed";
    }catch(Exception ex){error=ex.Message;}
   }
   return false;
  }
 }
 private bool Interrupted(){return queue.IsAddingCompleted || queue.Count!=0;}
 private bool RunOutput(Command command){
  for(int attempt=0;attempt<2;attempt++){
   try{
    if(command.Wave==null){output.Stop();error=null;return true;}
    if(!output.Play(command.Wave,command.AfterPrevious,Interrupted))return false;
    error=null;return true;
   }catch(TimeoutException ex){error=ex.Message;return false;}
   catch(Exception ex){
    error=ex.Message;
    try{output.Stop();output.CloseDevice();}catch{return false;}
    if(Interrupted())return false;
   }
  }
  return false;
 }
 private void Loop(){
  try{foreach(Command command in queue.GetConsumingEnumerable()){
   if(queue.IsAddingCompleted)break;
   if(command.WarmUp){
    try{output.WarmUp(command.Wave);}catch{}
    continue;
   }
   bool played=output==null ? Run(command.Wave) : RunOutput(command);
   if(command.Start!=null)command.Start.Complete(played);
  }}finally{
   if(output!=null){try{output.Dispose();}catch(Exception ex){error=ex.Message;}}
   else lock(gate){if(owner==this){try{Reset();}catch(Exception ex){error=ex.Message;}}}
   lock(queue){closed=true;queue.Dispose();}
  }
 }
 private void Enqueue(Command command){
  lock(queue){
   if(closed){if(command.Start!=null)command.Start.Complete(false);return;}
   if(!queue.TryAdd(command)){
    Command stale;
    if(queue.TryTake(out stale) && stale.Start!=null)stale.Start.Complete(false);
    queue.TryAdd(command);
   }
  }
 }
 public void Play(byte[] wave){Enqueue(new Command(wave,null));}
 public void WarmUp(byte[] wave){
  if(output!=null && wave!=null)Enqueue(new Command(wave,null,false,true));
 }
 public GptClickAudioStart PlayClickCue(byte[] wave){
  var start=new GptClickAudioStart();
  Enqueue(new Command(wave,start,true));
  return start;
 }
 public void Stop(){Play(null);}
 public void Dispose(){lock(queue){if(!closed){closed=true;queue.CompleteAdding();}}}
 public void Wait(int milliseconds){worker.Join(milliseconds);}
}
'@
}
function Read-WidgetPcmWave([string]$Path) {
    $file=[IO.File]::OpenRead($Path)
    try{
        if($file.Length-gt 10MB){throw '音效文件超过10MiB。'}
        $bytes=[byte[]]::new([int]$file.Length);$read=0
        while($read-lt $bytes.Length){$n=$file.Read($bytes,$read,$bytes.Length-$read);if(!$n){throw 'WAV文件不完整。'};$read+=$n}
        if($file.Length-ne $bytes.Length){throw '音效读取期间发生变化，请重试。'}
    }finally{$file.Dispose()}
    if($bytes.Length-lt 12 -or [Text.Encoding]::ASCII.GetString($bytes,0,4)-ne 'RIFF' -or [Text.Encoding]::ASCII.GetString($bytes,8,4)-ne 'WAVE' -or [long][BitConverter]::ToUInt32($bytes,4)+8-ne $bytes.Length){throw 'WAV文件损坏或不完整。'}
    $formatSeen=$false;$dataSeen=$false;$offset=12;$dataOffset=0;$dataLength=0;$rate=0;$align=0
    while($offset-lt $bytes.Length){
        if($offset+8-gt $bytes.Length){throw 'WAV文件不完整。'}
        $tag=[Text.Encoding]::ASCII.GetString($bytes,$offset,4);$size=[long][BitConverter]::ToUInt32($bytes,$offset+4);$body=$offset+8
        if($size+($size%2)-gt $bytes.Length-$body){throw 'WAV数据块不完整。'}
        if($tag-eq 'fmt '){
            if($formatSeen -or $size-lt 16){throw 'WAV格式块无效。'};$formatSeen=$true
            $channels=[BitConverter]::ToUInt16($bytes,$body+2);$rate=[BitConverter]::ToUInt32($bytes,$body+4);$align=[BitConverter]::ToUInt16($bytes,$body+12)
            if([BitConverter]::ToUInt16($bytes,$body)-ne 1 -or [BitConverter]::ToUInt16($bytes,$body+14)-ne 16 -or $channels-notin @(1,2) -or $rate-lt 8000 -or $rate-gt 192000 -or $align-ne $channels*2 -or [BitConverter]::ToUInt32($bytes,$body+8)-ne [long]$rate*$align){throw '缓存不是有效的16位PCM WAV。'}
        }elseif($tag-eq 'data'){
            if($dataSeen){throw 'WAV文件有重复音频块。'};$dataSeen=$true;$dataOffset=$body;$dataLength=[int]$size
        }
        $offset=$body+$size+($size%2)
    }
    if(!$formatSeen -or !$dataSeen -or $dataLength-le 0 -or $dataLength%$align-ne 0){throw 'WAV音频数据无效。'}
    if([long]$dataLength-gt [long]$rate*$align*5){throw '音效超过5秒，请选择不超过5秒的文件。'}
    return @{Path=$Path;Bytes=$bytes;Offset=$dataOffset;Length=$dataLength;Duration=([double]$dataLength/$align/$rate)}
}
function New-WidgetAudioClip([string]$Path,[double]$Volume,$Wave) {
    if(!$Wave){$Wave=Read-WidgetPcmWave $Path}
    return ,([GptNiangPcm]::Scale($wave.Bytes,$wave.Offset,$wave.Length,$Volume))
}

function Read-WidgetAudioPreferences([string]$DataDir,[switch]$Backup) {
    $prefs=@{version=1;mode='builtin';press=$null;release=$null}
    if(!$DataDir){return $prefs}
    $file=Join-Path $DataDir 'audio-preferences.json'
    if($Backup){$file+='.bak'}
    if(![IO.File]::Exists($file)){return $prefs}
    try{
        if((Get-Item -LiteralPath $file).Length-gt 16KB){throw 'Invalid audio preferences'}
        $saved=Get-Content -LiteralPath $file -Raw -Encoding UTF8|ConvertFrom-Json
        if($saved.version-ne 1 -or $saved.mode-notin @('builtin','custom')){throw 'Invalid audio preferences'}
        $prefs.mode=[string]$saved.mode
        foreach($slot in @('press','release')){
            $entry=$saved.$slot
            if($null-eq $entry){continue}
            if($entry.file-isnot [string] -or $entry.file-cnotmatch '^[a-f0-9]{32}\.wav$' -or $entry.name-isnot [string] -or $entry.name.Length-gt 255){throw 'Invalid audio entry'}
            $prefs[$slot]=@{file=$entry.file;name=$entry.name}
        }
    }catch{$prefs=@{version=1;mode='custom';press=$null;release=$null;loadError='音效设置无法读取，请重新选择音效。'}}
    return $prefs
}
function Copy-WidgetAudioPreferences($Preferences) {
    $copy=@{version=1;mode=$Preferences.mode;press=$null;release=$null}
    foreach($slot in @('press','release')){if($Preferences[$slot]){$copy[$slot]=@{file=$Preferences[$slot].file;name=$Preferences[$slot].name}}}
    return $copy
}
function Write-WidgetAudioPreferences([string]$DataDir,$Preferences) {
    if(!$DataDir){throw '个人音效目录不可用。'}
    $file=Join-Path $DataDir 'audio-preferences.json';$temporary=$file+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,($Preferences|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($file)){[IO.File]::Replace($temporary,$file,($file+'.bak'),$true)}else{[IO.File]::Move($temporary,$file)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Get-WidgetCustomAudioPath($Audio,[string]$Slot) {
    $entry=$Audio.Preferences[$Slot]
    if(!$entry -or !$Audio.DataDir){return $null}
    return Join-Path (Join-Path $Audio.DataDir 'sounds') $entry.file
}
function Close-WidgetAudioState($Audio,[switch]$NoWait) {
    if(!$Audio){return}
    $Audio.Timer.Stop()
    if($Audio.Queue){
        try{
            $Audio.Queue.Dispose()
            if(!$NoWait){$Audio.Queue.Wait(1000)}
        }catch{}
    }
    $Audio.Press=$null;$Audio.Release=$null
    $Audio.Waves.Clear()
}
function New-WidgetAudioState([string]$AppDir,[string]$DataDir,$Preferences) {
    $timer=[Windows.Threading.DispatcherTimer]::new()
    $audio=@{AppDir=$AppDir;DataDir=$DataDir;Preferences=$Preferences;Errors=@{}
        Press=$null;Release=$null;Waves=@{}
        Volume=(Get-WidgetAudioVolume);Timer=$timer;PressStart=$null;ReleaseStart=$null
        Queue=[GptClickAudioQueue]::new()
        Duration=0.0;ReleaseDuration=0.0;Pressing=$false;PendingRelease=$false;ReleasePlayed=$true}
    try{
        foreach($slot in @('press','release')){
            $source=if($Preferences.mode-eq 'builtin'){Join-Path $AppDir ('assets/'+$slot+'.wav')}else{Get-WidgetCustomAudioPath $audio $slot}
            if(!$source){continue}
            try{
                $wave=Read-WidgetPcmWave $source
                $audio[$slot]=New-WidgetAudioClip $source $audio.Volume -Wave $wave
                $audio.Waves[$slot]=$wave
                if($slot-eq 'press'){$audio.Duration=$wave.Duration}else{$audio.ReleaseDuration=$wave.Duration}
            }catch{
                if($Preferences.mode-eq 'builtin'){throw}
                $audio.Errors[$slot]='文件不可用，请重新选择。'
            }
        }
        if((Get-WidgetAudioEnabled) -and $audio.Volume-gt 0){
            if($audio.Press){$audio.Queue.WarmUp($audio.Press)}
            elseif($audio.Release){$audio.Queue.WarmUp($audio.Release)}
        }
        $timer.Add_Tick({
            param($sender,$event)
            $audio=$script:gptNiangAudio
            if(!$audio -or ![object]::ReferenceEquals($sender,$audio.Timer)){return}
            $audio.Timer.Stop()
            Update-WidgetReleaseTiming $audio
        })
        return $audio
    }catch{Close-WidgetAudioState $audio;throw}
}
function Set-WidgetAudioVolume {
    param([double]$Volume=-1)
    if($Volume-ge 0 -and ![double]::IsNaN($Volume) -and ![double]::IsInfinity($Volume)){$script:soundVolume=[Math]::Min(1.0,[Math]::Max(0.0,$Volume))}
    $value=Get-WidgetAudioVolume;$audio=$script:gptNiangAudio
    if(!$audio -or [Math]::Abs($audio.Volume-$value)-lt 0.000001){return}
    $clips=@{}
    try{
        foreach($slot in @('press','release')){
            $wave=$audio.Waves[$slot]
            if($wave){$clips[$slot]=New-WidgetAudioClip $wave.Path $value -Wave $wave}
        }
        foreach($slot in @('press','release')){
            if(!$clips[$slot]){continue}
            $audio[$slot]=$clips[$slot]
        }
        $audio.Volume=$value
        $audio.Queue.Stop()
    }catch{
        $script:soundVolume=$audio.Volume
    }
}
function Invoke-WidgetReleaseNow {
    $audio=$script:gptNiangAudio
    if(!$audio -or !$audio.PendingRelease -or $audio.ReleasePlayed){return}
    $audio.Timer.Stop();$audio.PendingRelease=$false;$audio.ReleasePlayed=$true;$audio.PressStart=$null
    if(!(Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume)-le 0 -or !$audio.Release){return}
    Set-WidgetAudioVolume
    # Native stop/play and recovery stay on the audio worker, away from dragging.
    if($audio.Queue){try{$audio.ReleaseStart=$audio.Queue.PlayClickCue($audio.Release)}catch{}}
}
function Update-WidgetReleaseTiming($Audio) {
    if(!$Audio.PendingRelease -or $Audio.Pressing){return}
    if($Audio.PressStart -and $Audio.Queue.IsRunning){
        # A queued press may still be waiting on the device when the mouse is released.
        $remaining=$Audio.PressStart.SecondsUntil($Audio.Duration+0.015)
        if($remaining-gt 0.002){
            if([double]::IsPositiveInfinity($remaining)){$remaining=0.025}
            $Audio.Timer.Interval=[TimeSpan]::FromSeconds($remaining);$Audio.Timer.Start();return
        }
    }
    Invoke-WidgetReleaseNow
}
function Stop-WidgetAudio {
    $audio=$script:gptNiangAudio
    if(!$audio){return}
    $audio.Timer.Stop();$audio.PendingRelease=$false;$audio.ReleasePlayed=$true;$audio.Pressing=$false;$audio.PressStart=$null;$audio.ReleaseStart=$null
    if($audio.Queue){try{$audio.Queue.Stop()}catch{}}
}
function Initialize-WidgetAudio {
    param([Parameter(Mandatory=$true)][string]$AppDir,[string]$DataDir)
    Close-WidgetAudio
    try{
        Add-Type -AssemblyName PresentationCore,WindowsBase,System
        $prefs=Read-WidgetAudioPreferences $DataDir
        $script:gptNiangAudio=New-WidgetAudioState $AppDir $DataDir $prefs
    }catch{$script:gptNiangAudio=$null}
}
function Close-WidgetAudio([switch]$NoWait) {
    if(!$script:gptNiangAudio){return}
    Close-WidgetAudioState $script:gptNiangAudio -NoWait:$NoWait
    $script:gptNiangAudio=$null
}
function Play-WidgetPressSound {
    $audio=$script:gptNiangAudio
    if(!$audio){return}
    # A rapid second click must not interrupt the previous click's release.
    if($audio.PendingRelease -or ($audio.ReleaseStart -and $audio.ReleaseStart.SecondsUntil($audio.ReleaseDuration)-gt 0)){return}
    $audio.Timer.Stop();$audio.PressStart=$null
    if(!(Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume)-le 0 -or (!$audio.Press -and !$audio.Release)){$audio.Pressing=$false;return}
    $audio.Pressing=$true;$audio.ReleasePlayed=$false
    Set-WidgetAudioVolume
    # The worker replaces the active clip without blocking the UI thread.
    if($audio.Press -and $audio.Queue){try{$audio.PressStart=$audio.Queue.PlayClickCue($audio.Press)}catch{}}
}
function Play-WidgetReleaseSound {
    $audio=$script:gptNiangAudio
    if(!$audio -or !$audio.Pressing){return}
    $audio.Pressing=$false
    if(!(Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume)-le 0){Stop-WidgetAudio;return}
    if(!$audio.Release){$audio.ReleasePlayed=$true;return}
    $audio.PendingRelease=$true
    Update-WidgetReleaseTiming $audio
}
function Remove-WidgetUnusedAudioFiles($Audio,$Preferences,$PreviousBackup) {
    # Only retire files named by the superseded backup. Do not sweep unrelated
    # files; retain the current settings and the new backup for recovery.
    if(!$Audio -or !$Audio.DataDir -or !$Preferences -or !$PreviousBackup -or $PreviousBackup.loadError){return}
    $backup=Read-WidgetAudioPreferences $Audio.DataDir -Backup
    if($backup.loadError){return}
    $keep=@{}
    foreach($set in @($Preferences,$backup)){
        foreach($slot in @('press','release')){$entry=$set[$slot];if($entry -and $entry.file){$keep[[string]$entry.file]=$true}}
    }
    $directory=Join-Path $Audio.DataDir 'sounds'
    try{
        foreach($slot in @('press','release')){
            $entry=$PreviousBackup[$slot]
            if($entry -and $entry.file-is [string] -and $entry.file-cmatch '^[a-f0-9]{32}\.wav$' -and !$keep.ContainsKey($entry.file)){
                try{[IO.File]::Delete((Join-Path $directory $entry.file))}catch{}
            }
        }
    }catch{}
}
function Set-WidgetAudioPreferences($Preferences,[string]$RequiredSlot) {
    $audio=$script:gptNiangAudio
    if(!$audio){throw '声音播放器尚未就绪。'}
    $previousBackup=Read-WidgetAudioPreferences $audio.DataDir -Backup
    $candidate=$null
    try{
        $candidate=New-WidgetAudioState $audio.AppDir $audio.DataDir $Preferences
        if($RequiredSlot -and !$candidate[$RequiredSlot]){throw '音效无法加载，原设置已保留。'}
        Write-WidgetAudioPreferences $audio.DataDir $Preferences
    }catch{Close-WidgetAudioState $candidate -NoWait;throw}
    Close-WidgetAudio -NoWait;$script:gptNiangAudio=$candidate
    # Cleanup is best-effort after committing settings; a cleanup failure must
    # not make the caller delete the newly committed custom clip.
    try{Remove-WidgetUnusedAudioFiles $candidate $Preferences $previousBackup}catch{}
}
function Import-WidgetAudio([ValidateSet('press','release')][string]$Slot,[string]$Path) {
    if(!$Path){return $false}
    $audio=$script:gptNiangAudio
    if(!$audio -or !$audio.DataDir){throw '个人音效目录不可用。'}
    $directory=Join-Path $audio.DataDir 'sounds';$null=[IO.Directory]::CreateDirectory($directory)
    $filename=[Guid]::NewGuid().ToString('N')+'.wav';$target=Join-Path $directory $filename
    $process=$null;$committed=$false
    try{
        $node=if($script:config.nodePath){$script:config.nodePath}else{(Get-Command node -ErrorAction Stop).Source}
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$node
        $info.Arguments='"'+(Join-Path $audio.AppDir 'runtime/audio-import.mjs')+'" "'+[IO.Path]::GetFullPath($Path)+'" "'+$target+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        if(!$process.Start()){throw '音效转换无法启动。'}
        if(!$process.WaitForExit(5000)){$process.Kill();$null=$process.WaitForExit(1000);throw '音效读取超时，请换一个文件。'}
        $result=$process.StandardOutput.ReadToEnd()|ConvertFrom-Json
        if(!$result.ok -or $process.ExitCode-ne 0){
            $message=switch($result.error){
                'too_long'{'音效超过5秒，请选择不超过5秒的文件。'}
                'too_large'{'音效文件超过10MiB，请选择较小的文件。'}
                'unsupported'{'不支持这种WAV编码，请选择其他音效文件。'}
                'io'{'无法读取或保存音效，请检查文件和个人目录。'}
                default{'WAV文件损坏或不完整，无法导入。'}
            }
            throw $message
        }
        $prefs=Copy-WidgetAudioPreferences $audio.Preferences
        $prefs.mode='custom';$prefs[$Slot]=@{file=$filename;name=[IO.Path]::GetFileName($Path)}
        Set-WidgetAudioPreferences $prefs $Slot;$committed=$true;return $true
    }finally{
        if($process){$process.Dispose()}
        if(!$committed -and [IO.File]::Exists($target)){[IO.File]::Delete($target)}
    }
}
function Set-WidgetAudioMode([ValidateSet('builtin','custom')][string]$Mode) {
    $prefs=Copy-WidgetAudioPreferences $script:gptNiangAudio.Preferences;$prefs.mode=$Mode
    Set-WidgetAudioPreferences $prefs
}
function Clear-WidgetAudioSlot([ValidateSet('press','release')][string]$Slot) {
    $prefs=Copy-WidgetAudioPreferences $script:gptNiangAudio.Preferences;$prefs.mode='custom';$prefs[$Slot]=$null
    Set-WidgetAudioPreferences $prefs
}
function Invoke-WidgetAudioPreview([ValidateSet('press','release')][string]$Slot) {
    $audio=$script:gptNiangAudio
    if(!$audio -or !(Get-WidgetAudioEnabled) -or (Get-WidgetAudioVolume)-le 0){return}
    $source=Get-WidgetCustomAudioPath $audio $Slot
    if(!$source){return}
    Stop-WidgetAudio
    try{
        $clip=New-WidgetAudioClip $source (Get-WidgetAudioVolume)
        $audio.Queue.Play($clip)
    }catch{throw ($audio.Preferences[$Slot].name+[Environment]::NewLine+'音效文件不可用，请重新选择。')}
}
function Select-WidgetAudioFile {
    $dialog=[Microsoft.Win32.OpenFileDialog]::new()
    $dialog.Title='选择WAV音效，最长5秒';$dialog.Filter='WAV音效 (*.wav)|*.wav';$dialog.Multiselect=$false;$dialog.CheckFileExists=$true
    if($dialog.ShowDialog($script:window)-eq $true){return $dialog.FileName}
    return $null
}
function Show-WidgetAudioError([string]$Message) {
    [Windows.MessageBox]::Show($script:window,$Message,'GPT 娘 · 音效',[Windows.MessageBoxButton]::OK,[Windows.MessageBoxImage]::Warning)|Out-Null
}
function Invoke-WidgetAudioAction([string]$Action,[string]$Slot) {
    $script:audioDialogOpen=$true
    try{
        switch($Action){
            'import'{$source=Select-WidgetAudioFile;if($source){try{$null=Import-WidgetAudio $Slot $source}catch{throw ([IO.Path]::GetFileName($source)+[Environment]::NewLine+$_.Exception.Message)}}}
            'clear'{Clear-WidgetAudioSlot $Slot}
            'builtin'{Set-WidgetAudioMode 'builtin'}
            'custom'{Set-WidgetAudioMode 'custom'}
            'preview'{Invoke-WidgetAudioPreview $Slot}
        }
    }catch{Show-WidgetAudioError $_.Exception.Message}
    finally{$script:audioDialogOpen=$false;Update-WidgetSettingsMenu}
}
function Get-WidgetAudioStatus {
    $audio=$script:gptNiangAudio
    $status=@{enabled=(Get-WidgetAudioEnabled);volume=(Get-WidgetAudioVolume);backend=$null;ready=[bool]$audio;mode='builtin';press=$null;release=$null}
    if(!$audio){return $status}
    $status.mode=$audio.Preferences.mode;$status.error=$audio.Preferences.loadError
    if($audio.Queue.Error){$status.error=$audio.Queue.Error}
    if($audio.Press -or $audio.Release){$status.backend='winmm.waveOut'}
    foreach($slot in @('press','release')){
        $entry=$audio.Preferences[$slot];$source=Get-WidgetCustomAudioPath $audio $slot
        $status[$slot]=@{name=if($entry){$entry.name}else{'无声'};configured=[bool]$entry;available=([bool]$source -and [IO.File]::Exists($source) -and !$audio.Errors[$slot]);active=[bool]$audio[$slot];error=$audio.Errors[$slot]}
    }
    return $status
}
