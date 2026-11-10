function Initialize-WidgetQuoteLayouts([string]$AppDir){
  if(!('GptWidgetQuoteLayout'-as [type])){
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    Add-Type -Path (Join-Path $AppDir 'runtime\quote-layout.cs') -ReferencedAssemblies 'System.Xaml',([Windows.Controls.TextBlock].Assembly.Location),([Windows.Media.FormattedText].Assembly.Location),([Windows.Point].Assembly.Location)
  }
  $script:quoteLayoutMap=@{};$script:quoteLayoutHints=@{};$script:quoteLayoutCache=@{}
  $file=Join-Path $AppDir 'assets\quote-layouts.json'
  if(![IO.File]::Exists($file)){return}
  try{
    $profiles=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json
    foreach($row in $profiles.quotes){
      if($row.text-isnot [string] -or $row.display-isnot [string]){continue}
      if(($row.text-replace '\s','')-cne ($row.display-replace '\s','')){continue}
      $script:quoteLayoutMap[$row.text]=$row.display
      if($row.layout){$script:quoteLayoutHints[$row.display]=$row.layout}
    }
  }catch{}
}

function Measure-WidgetQuoteLayout([string]$Value,$TextBlock,$Typeface,[double]$Size,[double]$Width,[int]$ExpectedLines=0){
  [GptWidgetQuoteLayout]::Measure($Value,$TextBlock,$Typeface,$Size,$Width,$ExpectedLines)
}

function Get-WidgetQuoteLayout([string]$Value,$TextBlock,[int]$ExpectedLines=0){
  $key=(@($TextBlock.FontFamily.Source,$TextBlock.FontStyle,$TextBlock.FontWeight,$TextBlock.FontStretch,[Globalization.CultureInfo]::CurrentCulture.Name)-join '|')+"`n"+$Value
  if($script:quoteLayoutCache.ContainsKey($key)){return $script:quoteLayoutCache[$key]}
  $hint=$script:quoteLayoutHints[$Value]
  # Verify a reviewed profile against this machine's fonts before reusing it.
  $best=[GptWidgetQuoteLayout]::Find($Value,$TextBlock,$ExpectedLines,[double]$hint.fontSize,[double]$hint.width,$script:quoteLayoutMap.ContainsValue($Value))
  if(!$best){throw 'Quote cannot fit inside the bubble'}
  if($script:quoteLayoutCache.Count-ge 200){$script:quoteLayoutCache.Clear()}
  $script:quoteLayoutCache[$key]=$best
  return $best
}

function Fit-QuoteText {
  $text=$script:ui.QuoteText;$full=$text.Text;$text.Tag=$full
  $text.HorizontalAlignment=[Windows.HorizontalAlignment]::Center;$text.VerticalAlignment=[Windows.VerticalAlignment]::Center
  $text.TextAlignment=[Windows.TextAlignment]::Center;$text.Margin=[Windows.Thickness]::new(0);$text.Padding=[Windows.Thickness]::new(0)
  $display=$full
  if($script:quoteLayoutMap.ContainsKey($full)){$display=$script:quoteLayoutMap[$full]}
  $expectedLines=if($display.Contains("`n")){($display-split "`n").Count}else{0}
  try{$script:quoteLayout=Get-WidgetQuoteLayout $display $text $expectedLines}
  catch{
    # Reflow only a failed display attempt; Tag retains the full original
    # for the tooltip and copy action, including its explicit line breaks.
    $display=($full-replace '\s+',' ').Trim()
    try{$script:quoteLayout=Get-WidgetQuoteLayout $display $text}
    catch{$display='…';$script:quoteLayout=Get-WidgetQuoteLayout $display $text}
  }
  $text.Text=$display;$text.Width=$script:quoteLayout.width;$text.FontSize=$script:quoteLayout.fontSize;$text.LineHeight=$script:quoteLayout.lineHeight
  $text.LineStackingStrategy=[Windows.LineStackingStrategy]::BlockLineHeight
  $text.RenderTransform=[Windows.Media.TranslateTransform]::new($script:quoteLayout.offsetX,$script:quoteLayout.offsetY)
}

function Set-WidgetSceneLayout {
  $scene=$script:ui.SceneText
  if($script:bubbleMode-in @('quote','completion','reminder') -and $script:quoteLayout){
    [Windows.Controls.Canvas]::SetLeft($scene,155-$script:quoteLayout.width/2);[Windows.Controls.Canvas]::SetTop($scene,18)
    $scene.Width=$script:quoteLayout.width;$scene.Height=134
  }else{
    [Windows.Controls.Canvas]::SetLeft($scene,63);[Windows.Controls.Canvas]::SetTop($scene,22)
    $scene.Width=184;$scene.Height=115
  }
}
