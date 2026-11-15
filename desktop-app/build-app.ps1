# Builds "Vagabond VTT.exe" next to vagabond-vtt.html, using the C# compiler built into Windows (.NET Framework 4).
# Nothing is downloaded. Run:  powershell -ExecutionPolicy Bypass -File desktop-app\build-app.ps1
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$root = Split-Path $src -Parent
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw "The .NET Framework 4 C# compiler wasn't found ($csc)." }

# ---- icon: gold d20 outline with a V, drawn here so there is no image file to keep around ----
Add-Type -AssemblyName System.Drawing
function New-IconPng([int]$s) {
  $bmp = New-Object Drawing.Bitmap $s, $s
  $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
  $u = $s / 64.0
  $r = 14 * $u; $x = 2 * $u; $w = 60 * $u
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $path.AddArc($x, $x, 2 * $r, 2 * $r, 180, 90); $path.AddArc($x + $w - 2 * $r, $x, 2 * $r, 2 * $r, 270, 90)
  $path.AddArc($x + $w - 2 * $r, $x + $w - 2 * $r, 2 * $r, 2 * $r, 0, 90); $path.AddArc($x, $x + $w - 2 * $r, 2 * $r, 2 * $r, 90, 90); $path.CloseFigure()
  $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(28, 26, 36))), $path)
  $hex = [Drawing.PointF[]]@((New-Object Drawing.PointF (32*$u), (7*$u)), (New-Object Drawing.PointF (54*$u), (19.5*$u)), (New-Object Drawing.PointF (54*$u), (44.5*$u)),
    (New-Object Drawing.PointF (32*$u), (57*$u)), (New-Object Drawing.PointF (10*$u), (44.5*$u)), (New-Object Drawing.PointF (10*$u), (19.5*$u)))
  $p1 = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(224, 178, 74)), ([Math]::Max(1.5, 4 * $u)); $p1.LineJoin = 'Round'
  $g.DrawPolygon($p1, $hex)
  $p2 = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(243, 210, 122)), ([Math]::Max(2, 5.5 * $u)); $p2.LineJoin = 'Round'; $p2.StartCap = 'Round'; $p2.EndCap = 'Round'
  $g.DrawLines($p2, [Drawing.PointF[]]@((New-Object Drawing.PointF (21*$u), (22*$u)), (New-Object Drawing.PointF (32*$u), (44*$u)), (New-Object Drawing.PointF (43*$u), (22*$u))))
  $g.Dispose(); $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  return ,$ms.ToArray()
}
$sizes = 16, 24, 32, 48, 64, 256
$pngs = @(foreach ($s in $sizes) { ,(New-IconPng $s) })
$ico = Join-Path $src 'vagabond.ico'
$ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $ms
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$off = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
  $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$off); $off += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write([byte[]]$p) }
$bw.Flush(); [IO.File]::WriteAllBytes($ico, $ms.ToArray())

# ---- compile ----
$out = Join-Path $root 'Vagabond VTT.exe'
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$out" "/win32icon:$ico" `
  /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll `
  (Join-Path $src 'VagabondVTT.cs')
if ($LASTEXITCODE -ne 0) { throw "Build failed." }
Write-Host "Built: $out" -ForegroundColor Green
