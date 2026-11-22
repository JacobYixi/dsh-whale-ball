param(
  [Parameter(Mandatory = $true)][string]$StatePath,
  [switch]$TestOpen
)

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 starts DPI-unaware, which makes WPF/WinForms coordinates and
# Win32 screen rectangles disagree on scaled displays: the ball and the chat
# window would be blurry and could be positioned off-screen. Opt into
# per-monitor DPI awareness before any window exists.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DqcDpi
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
'@
try {
  if (-not [DqcDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
    [void][DqcDpi]::SetProcessDpiAwarenessContext([IntPtr](-3))
  }
} catch {
  # Older Windows builds fall back to the process manifest/default.
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Do the balance HTTP request off the UI thread. The result is written to a
# small file so PowerShell never has to marshal a WebClient event back into the
# WPF runspace.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading.Tasks;
public static class DshBalanceFetcher
{
    public static void FetchToFile(string url, string token, string output)
    {
        Task.Run(() =>
        {
            string body = null, error = null;
            try
            {
                using (var client = new WebClient())
                {
                    client.Proxy = null;
                    client.Encoding = Encoding.UTF8;
                    if (!string.IsNullOrEmpty(token)) client.Headers.Add("x-dsh-balance-token", token);
                    body = client.DownloadString(url);
                }
            }
            catch (Exception ex) { error = ex.Message; }
            try
            {
                var temp = output + ".tmp";
                File.WriteAllText(temp, error != null ? "ERROR:" + error : body, Encoding.UTF8);
                File.Move(temp, output);
            }
            catch { }
        });
    }
}
'@

# A warm-up window must not steal focus when it appears off-screen on hover.
$script:canPrewarm = $false
try {
  Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class DqcChatForm : Form
{
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0083 && m.WParam != IntPtr.Zero)
        {
            m.Result = IntPtr.Zero;
            return;
        }
        if (m.Msg == 0x0084)
        {
            long packed = m.LParam.ToInt64();
            int screenX = (int)(packed & 0xFFFF);
            int screenY = (int)((packed >> 16) & 0xFFFF);
            if (screenX > 32767) screenX -= 65536;
            if (screenY > 32767) screenY -= 65536;
            Point point = PointToClient(new Point(screenX, screenY));
            int edge = 7;
            bool left = point.X < edge;
            bool right = point.X >= ClientSize.Width - edge;
            bool top = point.Y < edge;
            bool bottom = point.Y >= ClientSize.Height - edge;
            int result = 1;
            if (top && left) result = 13;
            else if (top && right) result = 14;
            else if (bottom && left) result = 16;
            else if (bottom && right) result = 17;
            else if (top) result = 12;
            else if (bottom) result = 15;
            else if (left) result = 10;
            else if (right) result = 11;
            m.Result = (IntPtr)result;
            return;
        }
        if (m.Msg == 0x00A1)
        {
            int hit = m.WParam.ToInt32();
            int direction = 0;
            if (hit == 10) direction = 1;
            else if (hit == 11) direction = 2;
            else if (hit == 12) direction = 3;
            else if (hit == 13) direction = 4;
            else if (hit == 14) direction = 5;
            else if (hit == 15) direction = 6;
            else if (hit == 16) direction = 7;
            else if (hit == 17) direction = 8;
            if (direction != 0)
            {
                m.Result = IntPtr.Zero;
                SendMessage(Handle, 0x0112, (IntPtr)(0xF000 + direction), IntPtr.Zero);
                return;
            }
        }
        base.WndProc(ref m);
    }
}

public sealed class DqcChatWarmForm : DqcChatForm
{
    protected override bool ShowWithoutActivation { get { return true; } }
}
'@
  $script:canPrewarm = $true
} catch {
  # Prewarming is optional; the chat window still works without it.
}

$nativeSource = @'
using System;
using System.Runtime.InteropServices;

public static class DqcBallNative
{
    public const int GWL_STYLE = -16;
    public const int GWL_EXSTYLE = -20;
    public const int WS_THICKFRAME = 0x00040000;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;
    public const int SW_HIDE = 0;
    public const uint WM_CLOSE = 0x0010;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_FRAMECHANGED = 0x0020;
    public const uint SWP_SHOWWINDOW = 0x0040;

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);

    [DllImport("user32.dll")]
    public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint attach, uint attachTo, bool attachFlag);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string path);

    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
'@
Add-Type -TypeDefinition $nativeSource -Language CSharp

try {
  $script:state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  exit 1
}

$script:statePath = $StatePath
$script:root = Split-Path -Parent $StatePath
$script:pidPath = Join-Path $script:root 'ball.pid'
$script:logPath = if ($script:state.log) { [string]$script:state.log } else { Join-Path $script:root 'ball.log' }
$script:positionPath = if ($script:state.positionFile) { [string]$script:state.positionFile } else { Join-Path $script:root 'ball-position.json' }
$script:balanceUrl = [string]$script:state.balanceUrl
$script:balanceToken = [string]$script:state.balanceToken
$script:balanceClient = $null
$script:balancePollTimer = $null
$script:balanceTempPath = $null
$script:balanceTimeoutTimer = $null
$script:balanceGeneration = 0
$script:balanceToolTipText = $null
$script:balanceToolTipLabel = '桌面悬浮球：点击打开'
$script:chatSizePath = Join-Path $script:root 'chat-size.json'
$script:chatWidth = 412.0
$script:chatHeight = 608.0
try {
  if (Test-Path -LiteralPath $script:chatSizePath) {
    $savedSize = Get-Content -LiteralPath $script:chatSizePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $savedWidth = [double]$savedSize.width
    $savedHeight = [double]$savedSize.height
    if ($savedWidth -ge 360 -and $savedWidth -le 1400) { $script:chatWidth = $savedWidth }
    if ($savedHeight -ge 480 -and $savedHeight -le 1600) { $script:chatHeight = $savedHeight }
  }
} catch { }
$script:dshPid = [int]$script:state.pid
$script:chatTitle = [string]$script:state.title
$script:chatUrl = [string]$script:state.url
$script:edgeProfile = [string]$script:state.edgeProfile
$script:webviewProfile = if ($script:state.webviewProfile) { [string]$script:state.webviewProfile } else { Join-Path $script:root 'webview-profile' }
$script:webViewReady = $false
$script:webViewVersion = ''
$script:chatForm = $null
$script:chatWebView = $null
$script:chatIdleTimer = $null
$script:chatPrewarmed = $false
$script:chatPrewarming = $false
$script:chatNavigationStarted = $false
$script:startupPrewarmTimer = $null
$script:chatSurface = [System.Drawing.Color]::FromArgb(247, 248, 250)
$script:chatGlass = $false
$script:chatPinned = $false
$script:chatDragging = $false
$script:chatResizeStart = $null
$script:chatDragCursor = New-Object System.Drawing.Point(0, 0)
$script:chatDragLeft = 0
$script:chatDragTop = 0
$script:dragging = $false
$script:moved = $false
$script:startLeft = 0.0
$script:startTop = 0.0
$script:startCursor = New-Object System.Drawing.Point(0, 0)
$script:dpiX = 1.0
$script:dpiY = 1.0
$script:appearancePath = Join-Path $script:root 'appearance.json'
$script:openRequestPath = Join-Path $script:root 'open.request'
$script:mediaRoot = Join-Path $script:root 'media'
$script:gifTimer = $null
$script:gifFrames = @()
$script:gifDelays = @()
$script:gifIndex = 0
$script:appearanceTimer = $null
$script:appearanceStamp = ''
$script:lastBallClickAt = [DateTime]::MinValue
$script:ballGradient = $null
$script:defaultBallFill = $null
$script:ballShape = 'circle'
$script:ballSize = 60.0
$script:ballCrop = $null
$script:themeVariant = ''

function Write-BallLog([string]$message) {
  try {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $message
    Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8
  } catch {
    # Logging must never break the ball.
  }
}

function Initialize-WebView2 {
  $script:webViewReady = $false
  $dllDir = Join-Path $PSScriptRoot 'webview2'
  $coreDll = Join-Path $dllDir 'Microsoft.Web.WebView2.Core.dll'
  $formsDll = Join-Path $dllDir 'Microsoft.Web.WebView2.WinForms.dll'
  if ((-not (Test-Path -LiteralPath $coreDll)) -or (-not (Test-Path -LiteralPath $formsDll))) {
    Write-BallLog 'WebView2 SDK files missing; falling back to the browser window'
    return
  }
  try {
    [void][DqcBallNative]::SetDllDirectory($dllDir)
    $env:PATH = "$dllDir;$env:PATH"
    [void][System.Reflection.Assembly]::UnsafeLoadFrom($coreDll)
    [void][System.Reflection.Assembly]::UnsafeLoadFrom($formsDll)
    $version = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'WebView2 runtime not found' }
    $script:webViewVersion = $version
    $script:webViewReady = $true
    Write-BallLog "WebView2 runtime $version"
  } catch {
    Write-BallLog "WebView2 unavailable: $_"
    $script:webViewReady = $false
  }
}

function Read-Appearance {
  try {
    if (-not (Test-Path -LiteralPath $script:appearancePath)) { return $null }
    return Get-Content -LiteralPath $script:appearancePath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    Write-BallLog "appearance read failed: $_"
    return $null
  }
}

function Write-Appearance {
  param([hashtable]$Value)
  try {
    New-Item -ItemType Directory -Force -Path $script:root | Out-Null
    $json = $Value | ConvertTo-Json -Depth 4
    # No BOM: the Node host parses this file with JSON.parse.
    [System.IO.File]::WriteAllText($script:appearancePath, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    Write-BallLog "appearance write failed: $_"
  }
}

function Get-ThemeVariant {
  # SystemUsesLightTheme = 0 means the Windows shell (taskbar, personalisation) is dark.
  try {
    $value = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -ErrorAction Stop).SystemUsesLightTheme
    if ($null -ne $value -and [int]$value -eq 0) { return 'dark' }
    return 'light'
  } catch {
    try {
      $value = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
      if ($null -ne $value -and [int]$value -eq 0) { return 'dark' }
    } catch { }
    return 'light'
  }
}

function Get-ThemeBallFile {
  $variant = Get-ThemeVariant
  $dir = Join-Path $PSScriptRoot 'theme'
  $file = Join-Path $dir ("fluke-{0}.png" -f $variant)
  if (Test-Path -LiteralPath $file) { return $file }
  $fallback = Join-Path $dir 'fluke-light.png'
  if (Test-Path -LiteralPath $fallback) { return $fallback }
  return $null
}

function Set-ThemeBall {
  # Draw the theme icon instead of the builtin glyph; returns $true when it took over.
  $file = Get-ThemeBallFile
  if (-not $file) { return $false }
  try {
    Set-BallImage $file
    $script:themeVariant = Get-ThemeVariant
    try { Update-BallTipCard } catch { }
    Write-BallLog ("theme ball applied: {0}" -f $file)
    return $true
  } catch {
    Write-BallLog "theme ball failed: $_"
    return $false
  }
}

function Get-CroppedBallFrame {
  param($Frame)
  if (-not $Frame) { return $null }
  $crop = $script:ballCrop
  if (-not $crop) { return $Frame }
  try {
    $width = [int]$Frame.PixelWidth
    $height = [int]$Frame.PixelHeight
    if ($width -le 0 -or $height -le 0) { return $Frame }
    $x = [int][Math]::Floor([double]$crop.x * $width)
    $y = [int][Math]::Floor([double]$crop.y * $height)
    $w = [int][Math]::Ceiling([double]$crop.w * $width)
    $h = [int][Math]::Ceiling([double]$crop.h * $height)
    $x = [Math]::Max(0, [Math]::Min($width - 2, $x))
    $y = [Math]::Max(0, [Math]::Min($height - 2, $y))
    $w = [Math]::Max(2, [Math]::Min($width - $x, $w))
    $h = [Math]::Max(2, [Math]::Min($height - $y, $h))
    $rect = New-Object System.Windows.Int32Rect -ArgumentList $x, $y, $w, $h
    return New-Object System.Windows.Media.Imaging.CroppedBitmap -ArgumentList $Frame, $rect
  } catch {
    Write-BallLog "ball crop failed: $_"
    return $Frame
  }
}

function Update-BallGeometry {
  if (-not $script:ball -or -not $script:window) { return }
  try {
    $size = [double]$script:ballSize
    if (-not [double]::IsNaN($size)) {
      $size = [Math]::Max([double]44, [Math]::Min([double]84, $size))
    } else {
      $size = 60
    }
    $script:ballSize = $size
    $shape = [string]$script:ballShape
    $ballWidth = $size
    $ballHeight = $size
    if ($shape -eq 'wide') {
      $ballWidth = $size * 1.5
      $ballHeight = $size
    } elseif ($shape -eq 'tall') {
      $ballWidth = $size
      $ballHeight = $size * 1.5
    }
    $windowWidth = $ballWidth + 24
    $windowHeight = $ballHeight + 24
    $oldWidth = [double]$script:window.Width
    $oldHeight = [double]$script:window.Height
    if ($oldWidth -gt 0 -and $oldHeight -gt 0 -and ($oldWidth -ne $windowWidth -or $oldHeight -ne $windowHeight)) {
      $script:window.Left = $script:window.Left - ($windowWidth - $oldWidth) / 2
      $script:window.Top = $script:window.Top - ($windowHeight - $oldHeight) / 2
    }
    $script:window.Width = $windowWidth
    $script:window.Height = $windowHeight
    $script:ball.Width = $ballWidth
    $script:ball.Height = $ballHeight
    if ($script:ballMedia) {
      $script:ballMedia.Width = $ballWidth
      $script:ballMedia.Height = $ballHeight
    }
    if ($script:ballSolid) {
      $script:ballSolid.Width = $ballWidth
      $script:ballSolid.Height = $ballHeight
    }
    if ($script:ballGlyph) {
      $glyph = [Math]::Max(18, [Math]::Min($ballWidth, $ballHeight) * 0.52)
      $script:ballGlyph.Width = $glyph
      $script:ballGlyph.Height = $glyph
    }
    if ($script:ballInnerRing) {
      $ring = [Math]::Max(20, [Math]::Min($ballWidth, $ballHeight) / 60 * 55)
      $script:ballInnerRing.Width = $ring
      $script:ballInnerRing.Height = $ring
    }
    if ($script:ballBorder) {
      $script:ballBorder.Width = $ballWidth
      $script:ballBorder.Height = $ballHeight
    }
    $shortSide = [Math]::Min($ballWidth, $ballHeight)
    $radius = switch ($shape) {
      'rounded' { $shortSide * 0.28 }
      'square' { $shortSide * 0.12 }
      'wide' { $shortSide * 0.18 }
      'tall' { $shortSide * 0.18 }
      default { $shortSide / 2 }
    }
    if ($script:ballSolid) {
      $script:ballSolid.RadiusX = $radius
      $script:ballSolid.RadiusY = $radius
    }
    if ($script:ballMedia) {
      $clipWidth = [Math]::Max(2, $ballWidth - 2)
      $clipHeight = [Math]::Max(2, $ballHeight - 2)
      $clipShort = [Math]::Min($clipWidth, $clipHeight)
      $clipRadius = switch ($shape) {
        'rounded' { $clipShort * 0.28 }
        'square' { $clipShort * 0.12 }
        'wide' { $clipShort * 0.18 }
        'tall' { $clipShort * 0.18 }
        default { $clipShort / 2 }
      }
      $clip = New-Object System.Windows.Media.RectangleGeometry
      $clip.Rect = New-Object System.Windows.Rect -ArgumentList 1, 1, $clipWidth, $clipHeight
      $clip.RadiusX = $clipRadius
      $clip.RadiusY = $clipRadius
      $script:ballMedia.Clip = $clip
    }
    if ($shape -ne 'circle') {
      if ($script:ballInnerRing) { $script:ballInnerRing.Visibility = [System.Windows.Visibility]::Collapsed }
      if ($script:ballBorder) { $script:ballBorder.Visibility = [System.Windows.Visibility]::Collapsed }
    }
    Write-BallLog ("ball geometry size={0} shape={1} width={2} height={3}" -f $size, $shape, $ballWidth, $ballHeight)
  } catch {
    Write-BallLog "ball geometry failed: $_"
  }
}

function Ball-KindOf {
  param([string]$File)
  $ext = [System.IO.Path]::GetExtension($File).ToLowerInvariant()
  if ($ext -in @('.mp4', '.wmv', '.avi', '.mov', '.webm')) { return 'video' }
  if ($ext -eq '.gif') { return 'gif' }
  return 'image'
}

function Stop-BallMedia {
  if ($script:gifTimer) {
    try { $script:gifTimer.Stop() } catch { }
    $script:gifTimer = $null
  }
  $script:gifFrames = @()
  $script:gifDelays = @()
  $script:gifIndex = 0
  if ($script:ballVideo) {
    try {
      $script:ballVideo.Stop()
      $script:ballVideo.Source = $null
    } catch { }
  }
  if ($script:ballImage) {
    try { $script:ballImage.Source = $null } catch { }
  }
}

function Set-BallRings {
  param([bool]$Visible)
  $show = $Visible -and ([string]$script:ballShape -eq 'circle')
  $visibility = if ($show) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  if ($script:ballInnerRing) { $script:ballInnerRing.Visibility = $visibility }
  if ($script:ballBorder) { $script:ballBorder.Visibility = $visibility }
}

function Set-BallBuiltin {
  Stop-BallMedia
  if ($script:ballMedia) { $script:ballMedia.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballGlyph) { $script:ballGlyph.Visibility = [System.Windows.Visibility]::Visible }
  if ($script:ballImage) { $script:ballImage.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballVideo) { $script:ballVideo.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballGradient) { $script:ballGradient.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballSolid) {
    $script:ballSolid.Visibility = [System.Windows.Visibility]::Visible
    if ($script:defaultBallFill) { $script:ballSolid.Fill = $script:defaultBallFill }
  }
  Set-BallRings $true
}

function Set-BallColor {
  param([string]$Color)
  Stop-BallMedia
  if ($script:ballMedia) { $script:ballMedia.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballGlyph) { $script:ballGlyph.Visibility = [System.Windows.Visibility]::Visible }
  if ($script:ballImage) { $script:ballImage.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballVideo) { $script:ballVideo.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballGradient) { $script:ballGradient.Visibility = [System.Windows.Visibility]::Collapsed }
  Set-BallRings $true
  try {
    $colorValue = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    $brush = New-Object System.Windows.Media.SolidColorBrush -ArgumentList $colorValue
    if ($script:ballSolid) {
      $script:ballSolid.Visibility = [System.Windows.Visibility]::Visible
      $script:ballSolid.Fill = $brush
    }
  } catch {
    Write-BallLog "ball color failed: $_"
    Set-BallBuiltin
  }
}

function Set-BallImage {
  param([string]$File)
  Stop-BallMedia
  $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
    (New-Object System.Uri($File, [System.UriKind]::Absolute)),
    [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  )
  $cropped = Get-CroppedBallFrame $frame
  if ($cropped -and $cropped.CanFreeze) { $cropped.Freeze() }
  $script:ballImage.Source = $cropped
  $script:ballImage.Visibility = [System.Windows.Visibility]::Visible
  $script:ballVideo.Visibility = [System.Windows.Visibility]::Collapsed
  $script:ballGlyph.Visibility = [System.Windows.Visibility]::Collapsed
  $script:ballMedia.Visibility = [System.Windows.Visibility]::Visible
  if ($script:ballGradient) { $script:ballGradient.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballSolid) { $script:ballSolid.Visibility = [System.Windows.Visibility]::Collapsed }
  Set-BallRings $false
}

function Set-BallGif {
  param([string]$File)
  Stop-BallMedia

  # WPF's GifBitmapDecoder returns wrong palettes for frames after the first
  # (the image turns into a black/white dither). GDI+ composites GIF frames
  # correctly, so decode there and hand plain BGRA frames to WPF.
  $image = [System.Drawing.Image]::FromFile($File)
  try {
    if (-not $image.FrameDimensionsList -or $image.FrameDimensionsList.Count -eq 0) {
      throw 'GIF 没有可播放的帧'
    }
    $dimension = New-Object System.Drawing.Imaging.FrameDimension($image.FrameDimensionsList[0])
    $count = [int]$image.GetFrameCount($dimension)
    if ($count -le 0) { throw 'GIF 没有可播放的帧' }

    $maxSide = 256.0
    $scale = [Math]::Min([double]1, $maxSide / [Math]::Max([double]$image.Width, [double]$image.Height))
    $targetWidth = [Math]::Max(1, [int][Math]::Round([double]$image.Width * $scale))
    $targetHeight = [Math]::Max(1, [int][Math]::Round([double]$image.Height * $scale))

    $delayProperty = $null
    try { $delayProperty = $image.GetPropertyItem(0x5100) } catch { }

    $frames = @()
    $delays = @()
    for ($index = 0; $index -lt $count; $index++) {
      [void]$image.SelectActiveFrame($dimension, $index)
      $bitmap = New-Object System.Drawing.Bitmap($targetWidth, $targetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
          $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
          $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
          $graphics.DrawImage($image, 0, 0, $targetWidth, $targetHeight)
        } finally {
          $graphics.Dispose()
        }

        $rect = New-Object System.Drawing.Rectangle(0, 0, $targetWidth, $targetHeight)
        $data = $bitmap.LockBits(
          $rect,
          [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        try {
          $stride = [Math]::Abs([int]$data.Stride)
          $buffer = New-Object byte[] ($stride * $targetHeight)
          [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buffer, 0, $buffer.Length)
        } finally {
          $bitmap.UnlockBits($data)
        }

        $source = [System.Windows.Media.Imaging.BitmapSource]::Create(
          $targetWidth,
          $targetHeight,
          96,
          96,
          [System.Windows.Media.PixelFormats]::Bgra32,
          $null,
          $buffer,
          $stride
        )
        $source.Freeze()
        $frames += $source
      } finally {
        $bitmap.Dispose()
      }

      $delay = 100
      if ($delayProperty -and $delayProperty.Value -and $delayProperty.Value.Length -ge (($index + 1) * 4)) {
        $centiseconds = [BitConverter]::ToInt32($delayProperty.Value, $index * 4)
        if ($centiseconds -gt 0) { $delay = $centiseconds * 10 }
      }
      $delays += [Math]::Max(30, $delay)
    }
  } finally {
    $image.Dispose()
  }

  if ($frames.Count -eq 0) { throw 'GIF 没有可播放的帧' }
  $script:gifFrames = $frames
  $script:gifDelays = $delays
  $script:gifIndex = 0
  $script:ballImage.Source = Get-CroppedBallFrame $frames[0]
  $script:ballImage.Visibility = [System.Windows.Visibility]::Visible
  $script:ballVideo.Visibility = [System.Windows.Visibility]::Collapsed
  $script:ballGlyph.Visibility = [System.Windows.Visibility]::Collapsed
  $script:ballMedia.Visibility = [System.Windows.Visibility]::Visible
  if ($script:ballGradient) { $script:ballGradient.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballSolid) { $script:ballSolid.Visibility = [System.Windows.Visibility]::Collapsed }
  Set-BallRings $false

  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds($delays[0])
  $timer.Add_Tick({
    if (-not $script:gifFrames -or $script:gifFrames.Count -eq 0) { return }
    $script:gifIndex = ($script:gifIndex + 1) % $script:gifFrames.Count
    if ($script:ballImage) { $script:ballImage.Source = Get-CroppedBallFrame $script:gifFrames[$script:gifIndex] }
    if ($script:gifTimer) {
      $script:gifTimer.Interval = [TimeSpan]::FromMilliseconds($script:gifDelays[$script:gifIndex])
    }
  })
  $script:gifTimer = $timer
  $timer.Start()
}

function Set-BallVideo {
  param([string]$File)
  Stop-BallMedia
  $script:ballVideo.Source = New-Object System.Uri($File, [System.UriKind]::Absolute)
  $script:ballVideo.Visibility = [System.Windows.Visibility]::Visible
  $script:ballImage.Visibility = [System.Windows.Visibility]::Collapsed
  $script:ballGlyph.Visibility = [System.Windows.Visibility]::Collapsed
  $script:ballMedia.Visibility = [System.Windows.Visibility]::Visible
  if ($script:ballGradient) { $script:ballGradient.Visibility = [System.Windows.Visibility]::Collapsed }
  if ($script:ballSolid) { $script:ballSolid.Visibility = [System.Windows.Visibility]::Collapsed }
  Set-BallRings $false
  try { $script:ballVideo.Play() } catch { }
}

function Apply-BallAppearance {
  param($Appearance)
  if (-not $Appearance) {
    $script:ballShape = 'circle'
    $script:ballSize = 60
    $script:ballCrop = $null
    if (Set-ThemeBall) { Update-BallGeometry; return }
    Set-BallBuiltin
    Update-BallGeometry
    return
  }
  try {
    if ([string]$Appearance.chatBackgroundType -eq 'color' -and -not [string]::IsNullOrWhiteSpace([string]$Appearance.chatBackgroundColor)) {
      $script:chatSurface = [System.Drawing.ColorTranslator]::FromHtml([string]$Appearance.chatBackgroundColor)
    }
  } catch { }
  $shape = [string]$Appearance.ballShape
  $script:ballShape = if ($shape -in @('rounded', 'square', 'wide', 'tall')) { $shape } else { 'circle' }
  try {
    $script:ballSize = if ($null -eq $Appearance.ballSize -or [string]::IsNullOrWhiteSpace([string]$Appearance.ballSize)) {
      60
    } else {
      [Math]::Max([double]44, [Math]::Min([double]84, [double]$Appearance.ballSize))
    }
  } catch {
    $script:ballSize = 60
  }
  $crop = $Appearance.ballCrop
  if ($crop) {
    try {
      $script:ballCrop = @{
        x = [Math]::Max([double]0, [Math]::Min([double]0.99, [double]$crop.x))
        y = [Math]::Max([double]0, [Math]::Min([double]0.99, [double]$crop.y))
        w = [Math]::Max(0.01, [Math]::Min(1, [double]$crop.w))
        h = [Math]::Max(0.01, [Math]::Min(1, [double]$crop.h))
      }
    } catch {
      $script:ballCrop = $null
    }
  } else {
    $script:ballCrop = $null
  }
  $kind = [string]$Appearance.ballKind
  if ($kind -eq 'color') {
    Set-BallColor ([string]$Appearance.ballColor)
    Write-BallLog ("ball appearance applied: kind=color color={0}" -f $Appearance.ballColor)
    Update-BallGeometry
    return
  }
  if ($kind -eq 'builtin') {
    if (Set-ThemeBall) { Update-BallGeometry; return }
    Set-BallBuiltin
    Update-BallGeometry
    return
  }
  $file = [string]$Appearance.ballFile
  if ([string]::IsNullOrWhiteSpace($file) -or -not (Test-Path -LiteralPath $file)) {
    Set-BallBuiltin
    Update-BallGeometry
    return
  }
  if ([string]::IsNullOrWhiteSpace($kind)) { $kind = Ball-KindOf $file }
  try {
    switch ($kind) {
      'video' { Set-BallVideo $file }
      'gif' { Set-BallGif $file }
      default { Set-BallImage $file }
    }
    Write-BallLog ("ball appearance applied: kind={0} file={1}" -f $kind, $file)
  } catch {
    Write-BallLog "ball appearance failed: $_"
    Set-BallBuiltin
  }
  Update-BallGeometry
}

function Read-State {
  try {
    $next = Get-Content -LiteralPath $script:statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:chatTitle = [string]$next.title
    $script:chatUrl = [string]$next.url
    $script:edgeProfile = [string]$next.edgeProfile
    if ($next.balanceUrl) { $script:balanceUrl = [string]$next.balanceUrl }
    if ($next.balanceToken) { $script:balanceToken = [string]$next.balanceToken }
    if ($next.webviewProfile) { $script:webviewProfile = [string]$next.webviewProfile }
    return $true
  } catch {
    Write-BallLog "state read failed: $_"
    return $false
  }
}

function Get-ChatBounds {
  try {
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    if ($dpi.DpiScaleX -gt 0) { $script:dpiX = [Math]::Max(0.5, $dpi.DpiScaleX) }
    if ($dpi.DpiScaleY -gt 0) { $script:dpiY = [Math]::Max(0.5, $dpi.DpiScaleY) }
  } catch {
    # Keep the last known scale.
  }
  $anchor = [System.Windows.Forms.Cursor]::Position
  $work = [System.Windows.Forms.Screen]::FromPoint($anchor).WorkingArea
  $maxWidthDip = [Math]::Max(360, ($work.Width / $script:dpiX) - 16)
  $maxHeightDip = [Math]::Max(480, ($work.Height / $script:dpiY) - 16)
  $widthDip = [Math]::Min($script:chatWidth, $maxWidthDip)
  $heightDip = [Math]::Min($script:chatHeight, $maxHeightDip)
  $width = [int][Math]::Round($widthDip * $script:dpiX)
  $height = [int][Math]::Round($heightDip * $script:dpiY)
  $ballLeft = [int][Math]::Round($window.Left * $script:dpiX)
  $ballTop = [int][Math]::Round($window.Top * $script:dpiY)
  $ballBottom = $ballTop + [int][Math]::Round($window.Height * $script:dpiY)
  $x = $ballLeft - $width - 12
  $y = $ballBottom - $height
  $minX = $work.Left + 8
  $minY = $work.Top + 8
  $maxX = $work.Right - $width - 8
  $maxY = $work.Bottom - $height - 8
  if ($maxX -lt $minX) { $maxX = $minX }
  if ($maxY -lt $minY) { $maxY = $minY }
  $x = [Math]::Max($minX, [Math]::Min($maxX, $x))
  $y = [Math]::Max($minY, [Math]::Min($maxY, $y))
  return @($x, $y, $width, $height)
}

function Start-ChatDrag {
  if (-not $script:chatForm) { return }
  $script:chatDragging = $true
  $script:chatDragCursor = [System.Windows.Forms.Cursor]::Position
  $script:chatDragLeft = $script:chatForm.Left
  $script:chatDragTop = $script:chatForm.Top
  Write-BallLog ("chat drag start at {0},{1}" -f $script:chatDragLeft, $script:chatDragTop)
}

function Move-ChatDrag {
  if (-not $script:chatDragging -or -not $script:chatForm -or $script:chatForm.IsDisposed) { return }
  $cursor = [System.Windows.Forms.Cursor]::Position
  $script:chatForm.Left = $script:chatDragLeft + ($cursor.X - $script:chatDragCursor.X)
  $script:chatForm.Top = $script:chatDragTop + ($cursor.Y - $script:chatDragCursor.Y)
}

function Stop-ChatDrag {
  if ($script:chatDragging -and $script:chatForm) {
    Write-BallLog ("chat drag end at {0},{1}" -f $script:chatForm.Left, $script:chatForm.Top)
  }
  $script:chatDragging = $false
}

function Handle-ChatMessage {
  param($messageArgs)
  try {
    $raw = $messageArgs.TryGetWebMessageAsString()
    $message = $raw | ConvertFrom-Json
    switch ([string]$message.type) {
      'dqc-close' {
        $target = $script:chatForm
        if ($target) {
          try {
            [void]$target.BeginInvoke([Action]{ Hide-ChatWindow })
          } catch {
            Hide-ChatWindow
          }
        }
      }
      'dqc-drag-start' { Start-ChatDrag }
      'dqc-drag-move' { Move-ChatDrag }
      'dqc-drag-end' { Stop-ChatDrag }
      'dqc-pin' { Set-ChatPinned ([bool]$message.pinned) }
      'dqc-minimize' { Minimize-ChatWindow }
      'dqc-surface' { Set-ChatSurface ([string]$message.color) }
      'dqc-focus-main' { Focus-MainWindow }
      'dqc-resize-start' { Start-ChatResize ([string]$message.edge) }
      'dqc-resize-move' { Move-ChatResize ([string]$message.edge) ([double]$message.dx) ([double]$message.dy) }
      'dqc-resize-end' { End-ChatResize }
      default { }
    }
  } catch {
    Write-BallLog "chat message failed: $_"
  }
}

function Start-ChatIdleTimer {
  if (-not $script:chatIdleTimer) {
    $script:chatIdleTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:chatIdleTimer.Interval = [TimeSpan]::FromMinutes(10)
    $script:chatIdleTimer.Add_Tick({
      $script:chatIdleTimer.Stop()
      if ($script:chatForm -and ((-not $script:chatForm.Visible) -or $script:chatPrewarmed)) {
        Write-BallLog 'chat idle timeout'
        Close-ChatWindow
      }
    })
  }
  $script:chatIdleTimer.Stop()
  $script:chatIdleTimer.Start()
}

function Stop-ChatIdleTimer {
  if ($script:chatIdleTimer) { $script:chatIdleTimer.Stop() }
}

function Activate-ChatWindow {
  $form = $script:chatForm
  if (-not $form -or $form.IsDisposed) { return }
  try {
    $handle = $form.Handle
    $foregroundPid = [uint32]0
    $targetPid = [uint32]0
    $foregroundThread = [DqcBallNative]::GetWindowThreadProcessId([DqcBallNative]::GetForegroundWindow(), [ref]$foregroundPid)
    $targetThread = [DqcBallNative]::GetWindowThreadProcessId($handle, [ref]$targetPid)
    $attached = $false
    if ($foregroundThread -ne 0 -and $foregroundThread -ne $targetThread) {
      $attached = [DqcBallNative]::AttachThreadInput($foregroundThread, $targetThread, $true)
    }
    [void][DqcBallNative]::SetForegroundWindow($handle)
    if ($attached) { [void][DqcBallNative]::AttachThreadInput($foregroundThread, $targetThread, $false) }
  } catch {
    Write-BallLog "chat activate failed: $_"
  }
}

function Set-ChatSurface {
  param([string]$Color)
  if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return }
  if ([string]::IsNullOrWhiteSpace($Color)) { return }
  try {
    $surface = [System.Drawing.ColorTranslator]::FromHtml($Color)
    $script:chatSurface = $surface
    $script:chatForm.BackColor = $surface
    if ($script:chatWebView) { $script:chatWebView.DefaultBackgroundColor = $surface }
    try {
      $borderValue = -2
      [void][DqcBallNative]::DwmSetWindowAttribute($script:chatForm.Handle, 34, [ref]$borderValue, 4)
    } catch { }
    Write-BallLog ("chat surface {0}" -f $Color)
  } catch {
    Write-BallLog "chat surface failed: $_"
  }
}

function Focus-MainWindow {
  try {
    $process = Get-Process -Id $script:dshPid -ErrorAction Stop
    $handle = $process.MainWindowHandle
    if ($handle -ne [IntPtr]::Zero) {
      [void][DqcBallNative]::ShowWindow($handle, 9)
      [void][DqcBallNative]::SetForegroundWindow($handle)
      Write-BallLog 'focused DSH main window'
      return
    }
  } catch {
    Write-BallLog "focus main window failed: $_"
  }
}

function Update-ChatRegion {
  if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return }
  try {
    [void][DqcBallNative]::SetWindowRgn($script:chatForm.Handle, [IntPtr]::Zero, $true)
  } catch {
    Write-BallLog "chat region reset failed: $_"
  }
}

function Set-ChatPinned {
  param([bool]$Pinned)
  if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return }
  try {
    $script:chatPinned = $Pinned
    $script:chatForm.TopMost = $Pinned
    $after = if ($Pinned) { [DqcBallNative]::HWND_TOPMOST } else { [IntPtr](-2) }
    [void][DqcBallNative]::SetWindowPos(
      $script:chatForm.Handle,
      $after,
      0, 0, 0, 0,
      ([DqcBallNative]::SWP_NOMOVE -bor [DqcBallNative]::SWP_NOSIZE -bor [DqcBallNative]::SWP_SHOWWINDOW)
    )
    Write-BallLog ("chat pinned={0}" -f $Pinned)
  } catch {
    Write-BallLog "chat pin failed: $_"
  }
}

function Minimize-ChatWindow {
  if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return }
  try {
    Hide-ChatWindow
    Write-BallLog 'chat minimized to ball'
  } catch {
    Write-BallLog "chat minimize failed: $_"
  }
}

if (-not ('DqcGlassNative' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public struct DqcAccentPolicy { public int AccentState; public int AccentFlags; public int GradientColor; public int AnimationId; }
public struct DqcWindowComposition { public int Attribute; public IntPtr Data; public int SizeOfData; }
public static class DqcGlassNative {
  [DllImport("user32.dll")]
  public static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref DqcWindowComposition data);
  public static int Apply(IntPtr hwnd, int state, int gradient) {
    DqcAccentPolicy policy = new DqcAccentPolicy();
    policy.AccentState = state;
    policy.AccentFlags = 2;
    policy.GradientColor = gradient;
    policy.AnimationId = 0;
    IntPtr buffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(DqcAccentPolicy)));
    try {
      Marshal.StructureToPtr(policy, buffer, false);
      DqcWindowComposition data = new DqcWindowComposition();
      data.Attribute = 19;
      data.Data = buffer;
      data.SizeOfData = Marshal.SizeOf(typeof(DqcAccentPolicy));
      return SetWindowCompositionAttribute(hwnd, ref data);
    } finally {
      Marshal.FreeHGlobal(buffer);
    }
  }
}
'@
}

function Set-ChatGlass {
  param($Form)
  if (-not $script:chatGlass -or -not $Form -or $Form.IsDisposed) { return }
  try {
    $handle = $Form.Handle
    if ($handle -eq [IntPtr]::Zero) { return }
    $variant = 'light'
    try { $variant = [string]$script:themeVariant } catch { }
    # 0xAABBGGRR
    $tint = if ($variant -eq 'dark') { [int]0x99221D1D } else { [int]0x66FFFFFF }
    [void][DqcGlassNative]::Apply($handle, 4, $tint)
  } catch {
    Write-BallLog "chat glass failed: $_"
  }
}

function Show-ChatWindow {
  if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return $false }
  try {
    Stop-ChatIdleTimer
    if ($script:chatForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
      $script:chatForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    if ($script:chatPrewarmed) {
      $bounds = Get-ChatBounds
      $script:chatForm.Bounds = New-Object System.Drawing.Rectangle($bounds[0], $bounds[1], $bounds[2], $bounds[3])
      $script:chatForm.TopMost = $script:chatPinned
      $script:chatPrewarmed = $false
      Write-BallLog 'chat window promoted from warm'
    }
    if (-not $script:chatForm.Visible) { $script:chatForm.Show() }
    $script:chatForm.Activate()
    $afterPin = if ($script:chatPinned) { [DqcBallNative]::HWND_TOPMOST } else { [IntPtr](-2) }
    [void][DqcBallNative]::SetWindowPos(
      $script:chatForm.Handle,
      $afterPin,
      0, 0, 0, 0,
      ([DqcBallNative]::SWP_NOMOVE -bor [DqcBallNative]::SWP_NOSIZE -bor [DqcBallNative]::SWP_SHOWWINDOW)
    )
    Activate-ChatWindow
  } catch {
    Write-BallLog "chat show failed: $_"
    return $false
  }
  return $true
}

function Hide-ChatWindow {
  if ($script:chatForm -and -not $script:chatForm.IsDisposed) {
    try {
      $script:chatForm.Hide()
      Start-ChatIdleTimer
      Write-BallLog 'chat window hidden'
    } catch {
      Write-BallLog "chat hide failed: $_"
      Close-ChatWindow
    }
  }
}

function Close-ChatWindow {
  Stop-ChatIdleTimer
  $form = $script:chatForm
  $script:chatForm = $null
  $script:chatWebView = $null
  $script:chatDragging = $false
  $script:chatPrewarmed = $false
  $script:chatNavigationStarted = $false
  if ($form) {
    try {
      if (-not $form.IsDisposed) {
        $form.Close()
        $form.Dispose()
      }
    } catch {
      Write-BallLog "chat close failed: $_"
    }
  }
}

function New-ChatWindow {
  param([switch]$Prewarm)
  if ($script:chatForm -and -not $script:chatForm.IsDisposed) { return $true }
  $script:chatForm = $null
  $script:chatNavigationStarted = $false
  Write-BallLog ($(if ($Prewarm) { 'chat form prewarming' } else { 'chat form creating' }))
  $bounds = Get-ChatBounds
  if ($Prewarm) {
    $virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bounds[0] = $virtual.Left - $bounds[2] - 100
    $bounds[1] = $virtual.Top - $bounds[3] - 100
  }
  $form = if ($Prewarm) { New-Object DqcChatWarmForm } else { New-Object DqcChatForm }
  $form.Text = $script:chatTitle
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $form.ShowInTaskbar = $false
  $form.TopMost = $false
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.Left = $bounds[0]
  $form.Top = $bounds[1]
  $form.Width = $bounds[2]
  $form.Height = $bounds[3]
  $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList @(
    [int][Math]::Round(360 * $script:dpiX),
    [int][Math]::Round(480 * $script:dpiY)
  )
  $form.BackColor = $script:chatSurface
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  $form.MinimizeBox = $false
  $form.MaximizeBox = $false
  $form.ControlBox = $false
  $script:chatForm = $form

  $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
  $wv.Dock = [System.Windows.Forms.DockStyle]::Fill
  try { $wv.DefaultBackgroundColor = $script:chatSurface } catch { }
  $creation = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
  $creation.UserDataFolder = $script:webviewProfile
  $wv.CreationProperties = $creation
  $script:chatWebView = $wv
  $form.Controls.Add($wv)

  $wv.add_NavigationCompleted({
    param($sender, $eventArgs)
    Write-BallLog ("chat nav success={0} status={1}" -f $eventArgs.IsSuccess, $eventArgs.WebErrorStatus)
  })

  $wv.add_CoreWebView2InitializationCompleted({
    param($sender, $eventArgs)
    try {
      if (-not $eventArgs.IsSuccess) {
        Write-BallLog ("chat webview init failed: " + $eventArgs.InitializationException)
        if ($script:chatPrewarmed) {
          $warm = $script:chatForm
          if ($warm) {
            try { [void]$warm.BeginInvoke([Action]{ Close-ChatWindow }) } catch { Close-ChatWindow }
          } else {
            Close-ChatWindow
          }
          return
        }
        $target = $script:chatForm
        if ($target) {
          try {
            [void]$target.BeginInvoke([Action]{
              Close-ChatWindow
              Open-BrowserChat
            })
          } catch {
            Close-ChatWindow
            Open-BrowserChat
          }
        } else {
          Close-ChatWindow
          Open-BrowserChat
        }
        return
      }
      $core = $sender.CoreWebView2
      Write-BallLog ("chat webview ready " + $core.Environment.BrowserVersionString)
      $core.Settings.IsStatusBarEnabled = $false
      try {
        $bg = '#{0:x2}{1:x2}{2:x2}' -f $script:chatSurface.R, $script:chatSurface.G, $script:chatSurface.B
        $bootScript = @"
(function () {
  var css = 'html,body{background:$bg !important;}';
  function paint() {
    if (!document.documentElement) return;
    var style = document.getElementById('dqc-boot-bg');
    if (!style) {
      style = document.createElement('style');
      style.id = 'dqc-boot-bg';
      style.textContent = css;
      document.documentElement.appendChild(style);
    }
  }
  if (document.documentElement) paint();
  document.addEventListener('DOMContentLoaded', paint);
})();
"@
        [void]$core.AddScriptToExecuteOnDocumentCreatedAsync($bootScript)
      } catch {
        Write-BallLog "chat boot background failed: $_"
      }
      $core.add_NewWindowRequested({
        param($coreSender, $newWindowArgs)
        try {
          if ($newWindowArgs.Uri -match '^https?://') { Start-Process $newWindowArgs.Uri }
        } catch { }
        $newWindowArgs.Handled = $true
      })
      $core.add_WebMessageReceived({
        param($coreSender, $messageArgs)
        Handle-ChatMessage $messageArgs
      })
      $core.add_ProcessFailed({
        param($coreSender, $failedArgs)
        Write-BallLog ("chat webview process failed: " + $failedArgs.ProcessFailedKind)
      })
    } catch {
      Write-BallLog "chat init handler failed: $_"
    }
  })

  $form.Add_Activated({
    try {
      if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return }
      $noBorder = -2
      [void][DqcBallNative]::DwmSetWindowAttribute($script:chatForm.Handle, 34, [ref]$noBorder, 4)
    } catch { }
  })

  $form.Add_Shown({
    try {
      $handle = $script:chatForm.Handle
      $preference = 2
      [void][DqcBallNative]::DwmSetWindowAttribute($handle, 33, [ref]$preference, 4)
      $borderColor = -2
      [void][DqcBallNative]::DwmSetWindowAttribute($handle, 34, [ref]$borderColor, 4)
      $style = [DqcBallNative]::GetWindowLong($handle, [DqcBallNative]::GWL_EXSTYLE)
      [void][DqcBallNative]::SetWindowLong($handle, [DqcBallNative]::GWL_EXSTYLE, ($style -bor [DqcBallNative]::WS_EX_TOOLWINDOW))
      Update-ChatRegion
      $script:chatNavigationStarted = $true
      $script:chatWebView.Source = [Uri]$script:chatUrl
      Write-BallLog "chat window shown"
    } catch {
      Write-BallLog "chat window shown failed: $_"
      Close-ChatWindow
      Open-BrowserChat
    }
  })

  $form.Add_SizeChanged({
    Update-ChatRegion
  })

  $form.Add_ResizeEnd({
    Update-ChatRegion
    Save-ChatSize
  })

  $form.Add_FormClosed({
    $closed = $script:chatForm
    $script:chatForm = $null
    $script:chatWebView = $null
    $script:chatDragging = $false
    Write-BallLog 'chat window closed'
    if ($closed) {
      try { $closed.Dispose() } catch { }
    }
  })

  $form.Show()
  if (-not $Prewarm) { $form.Activate() }
  $script:chatPrewarmed = [bool]$Prewarm
  if ($Prewarm) {
    Start-ChatIdleTimer
    Write-BallLog 'chat window warmed'
  }
  Write-BallLog ("chat bounds requested={0},{1} {2}x{3}; actual={4},{5} {6}x{7}; dpi={8}x{9}; ball={10},{11} {12}x{13}; screen={14}; virtual={15}" -f $bounds[0], $bounds[1], $bounds[2], $bounds[3], $form.Left, $form.Top, $form.Width, $form.Height, $script:dpiX, $script:dpiY, $window.Left, $window.Top, $window.Width, $window.Height, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds, [System.Windows.Forms.SystemInformation]::VirtualScreen)
  return $true
}

function Find-Browser {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return $null
}

function Prewarm-ChatWindow {
  if (-not $script:canPrewarm) { return }
  if ($script:chatForm -or $script:chatPrewarming -or -not $script:webViewReady) { return }
  $script:chatPrewarming = $true
  try {
    [void](New-ChatWindow -Prewarm)
  } catch {
    Write-BallLog "chat prewarm failed: $_"
    Close-ChatWindow
  } finally {
    $script:chatPrewarming = $false
  }
}

function Open-BrowserChat {
  $browser = Find-Browser
  if (-not $browser) {
    Write-BallLog 'no Edge/Chrome found; opening the default browser'
    try {
      Start-Process $script:chatUrl
    } catch {
      Write-BallLog "default browser launch failed: $_"
    }
    return
  }
  try {
    New-Item -ItemType Directory -Force -Path $script:edgeProfile | Out-Null
  } catch {
    Write-BallLog "profile directory failed: $_"
  }
  $bounds = Get-ChatBounds
  $argumentLine = '--app="' + $script:chatUrl + '" --user-data-dir="' + $script:edgeProfile + '" --no-first-run --no-default-browser-check --disable-sync --disable-extensions --disable-component-extensions-with-background-pages --no-service-autorun --disable-features=msEdgeFirstRunExperience,msEdgeSyncConfirmation,msImplicitSignin,msEdgeSidebarV2,msEdgeWorkspaces,msEdgeTranslate --window-size=440,660 --window-position=' + $bounds[0] + ',' + $bounds[1]
  try {
    Start-Process -FilePath $browser -ArgumentList $argumentLine | Out-Null
    Write-BallLog "chat window requested: $browser"
  } catch {
    Write-BallLog "browser launch failed: $_"
  }
}

function Open-Chat {
  if (-not (Read-State)) { return }
  Write-BallLog 'open chat requested'
  if (Show-ChatWindow) { return }
  if (-not $script:webViewReady) {
    Open-BrowserChat
    return
  }
  try {
    if (New-ChatWindow) { return }
  } catch {
    Write-BallLog "webview chat failed: $_"
    Close-ChatWindow
  }
  Open-BrowserChat
}

function Save-Position {
  try {
    # Store both absolute DIP coordinates and a monitor-relative fraction, so a
    # different monitor layout (unplugged screen, new resolution) can remap it.
    $fx = $null
    $fy = $null
    $mon = $null
    try {
      $scaleX = if ($script:dpiX -gt 0) { $script:dpiX } else { 1 }
      $scaleY = if ($script:dpiY -gt 0) { $script:dpiY } else { 1 }
      $centerX = [int](($window.Left + ($window.Width / 2)) * $scaleX)
      $centerY = [int](($window.Top + ($window.Height / 2)) * $scaleY)
      $screen = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($centerX, $centerY)))
      if ($screen) {
        $area = $screen.WorkingArea
        $areaLeft = $area.Left / $scaleX
        $areaTop = $area.Top / $scaleY
        $areaWidth = $area.Width / $scaleX
        $areaHeight = $area.Height / $scaleY
        if ($areaWidth -gt 0) { $fx = [Math]::Round(($window.Left - $areaLeft) / $areaWidth, 4) }
        if ($areaHeight -gt 0) { $fy = [Math]::Round(($window.Top - $areaTop) / $areaHeight, 4) }
        $mon = [string]$screen.DeviceName
      }
    } catch {
      Write-BallLog "position fraction failed: $_"
    }
    $payload = @{ x = [double]$window.Left; y = [double]$window.Top; fx = $fx; fy = $fy; mon = $mon } | ConvertTo-Json -Compress
    $parent = Split-Path -Parent $script:positionPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Set-Content -LiteralPath $script:positionPath -Value $payload -Encoding UTF8
  } catch {
    Write-BallLog "position save failed: $_"
  }
}

function Save-ChatSize {
  try {
    if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return }
    $scaleX = [Math]::Max(0.5, $script:dpiX)
    $scaleY = [Math]::Max(0.5, $script:dpiY)
    $width = [Math]::Round($script:chatForm.Width / $scaleX)
    $height = [Math]::Round($script:chatForm.Height / $scaleY)
    if ($width -lt 360) { $width = 360 }
    if ($height -lt 480) { $height = 480 }
    if ($width -gt 1400) { $width = 1400 }
    if ($height -gt 1600) { $height = 1600 }
    $script:chatWidth = [double]$width
    $script:chatHeight = [double]$height
    $payload = @{ width = [double]$width; height = [double]$height } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($script:chatSizePath, $payload, (New-Object System.Text.UTF8Encoding($false)))
    Write-BallLog ("chat size saved {0}x{1} dip" -f $width, $height)
  } catch {
    Write-BallLog "chat size save failed: $_"
  }
}

function Set-ChatWindowSize {
  param([double]$Width, [double]$Height)
  if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return }
  try {
    $scaleX = [Math]::Max(0.5, $script:dpiX)
    $scaleY = [Math]::Max(0.5, $script:dpiY)
    $width = [Math]::Max(360, [Math]::Min(1400, $Width))
    $height = [Math]::Max(480, [Math]::Min(1600, $Height))
    $script:chatForm.Width = [int][Math]::Round($width * $scaleX)
    $script:chatForm.Height = [int][Math]::Round($height * $scaleY)
    Update-ChatRegion
    Write-BallLog ("chat resize requested {0}x{1}" -f $width, $height)
  } catch {
    Write-BallLog "chat resize failed: $_"
  }
}

function Start-ChatResize {
  param([string]$Edge)
  if (-not $script:chatForm -or $script:chatForm.IsDisposed) { return }
  $script:chatResizeStart = @{
    edge = $Edge
    left = $script:chatForm.Left
    top = $script:chatForm.Top
    width = $script:chatForm.Width
    height = $script:chatForm.Height
  }
}

function Move-ChatResize {
  param([string]$Edge, [double]$Dx, [double]$Dy)
  if (-not $script:chatForm -or $script:chatForm.IsDisposed -or -not $script:chatResizeStart) { return }
  try {
    $start = $script:chatResizeStart
    $scaleX = [Math]::Max(0.5, $script:dpiX)
    $scaleY = [Math]::Max(0.5, $script:dpiY)
    $dx = [int][Math]::Round($Dx * $scaleX)
    $dy = [int][Math]::Round($Dy * $scaleY)
    $left = [int]$start.left
    $top = [int]$start.top
    $width = [int]$start.width
    $height = [int]$start.height
    $right = $left + $width
    $bottom = $top + $height

    if ($Edge -match 'e') { $width = [int]$start.width + $dx }
    if ($Edge -match 'w') { $width = [int]$start.width - $dx; $left = [int]$start.left + $dx }
    if ($Edge -match 's') { $height = [int]$start.height + $dy }
    if ($Edge -match 'n') { $height = [int]$start.height - $dy; $top = [int]$start.top + $dy }

    $minWidth = [int][Math]::Round(360 * $scaleX)
    $minHeight = [int][Math]::Round(480 * $scaleY)
    $maxWidth = [int][Math]::Round(1400 * $scaleX)
    $maxHeight = [int][Math]::Round(1600 * $scaleY)

    if ($width -lt $minWidth) {
      if ($Edge -match 'w') { $left = $right - $minWidth }
      $width = $minWidth
    }
    if ($height -lt $minHeight) {
      if ($Edge -match 'n') { $top = $bottom - $minHeight }
      $height = $minHeight
    }
    if ($width -gt $maxWidth) {
      if ($Edge -match 'w') { $left = $right - $maxWidth }
      $width = $maxWidth
    }
    if ($height -gt $maxHeight) {
      if ($Edge -match 'n') { $top = $bottom - $maxHeight }
      $height = $maxHeight
    }

    $script:chatForm.SetBounds($left, $top, $width, $height)
    Update-ChatRegion
  } catch {
    Write-BallLog "chat edge resize failed: $_"
  }
}

function End-ChatResize {
  $script:chatResizeStart = $null
  Save-ChatSize
}

function Snap-BallToEdge {
  try {
    if (-not $script:moved) { return }
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $scaleX = [Math]::Max(0.5, $dpi.DpiScaleX)
    $scaleY = [Math]::Max(0.5, $dpi.DpiScaleY)
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    $screen = if ($handle -ne [IntPtr]::Zero) {
      [System.Windows.Forms.Screen]::FromHandle($handle)
    } else {
      [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    }
    $work = $screen.WorkingArea
    $workLeft = $work.Left / $scaleX
    $workTop = $work.Top / $scaleY
    $workRight = ($work.Left + $work.Width) / $scaleX
    $workBottom = ($work.Top + $work.Height) / $scaleY

    $size = [double]$script:ballSize
    if ([double]::IsNaN($size) -or $size -le 0) { $size = 60 }
    $inset = ($window.Width - $size) / 2
    $ballLeft = $window.Left + $inset
    $ballTop = $window.Top + $inset
    $ballRight = $ballLeft + $size
    $ballBottom = $ballTop + $size
    $threshold = 26
    $peekX = $size / 2
    $peekY = $size / 2
    $targetLeft = $window.Left
    $targetTop = $window.Top

    $leftDistance = [Math]::Abs($ballLeft - $workLeft)
    $rightDistance = [Math]::Abs($workRight - $ballRight)
    $topDistance = [Math]::Abs($ballTop - $workTop)
    $bottomDistance = [Math]::Abs($workBottom - $ballBottom)

    if ($leftDistance -le $threshold -and $leftDistance -le $rightDistance) {
      $targetLeft = $workLeft - $peekX - $inset
    } elseif ($rightDistance -le $threshold) {
      $targetLeft = $workRight + $peekX - $size - $inset
    }
    if ($topDistance -le $threshold -and $topDistance -le $bottomDistance) {
      $targetTop = $workTop - $peekY - $inset
    } elseif ($bottomDistance -le $threshold) {
      $targetTop = $workBottom + $peekY - $size - $inset
    }

    if ([Math]::Abs($targetLeft - $window.Left) -gt 0.5 -or [Math]::Abs($targetTop - $window.Top) -gt 0.5) {
      $window.Left = $targetLeft
      $window.Top = $targetTop
      Write-BallLog ("ball snapped to {0},{1}" -f $targetLeft, $targetTop)
    }
  } catch {
    Write-BallLog "ball snap failed: $_"
  }
}

function ConvertTo-BallBrush {
  param([string]$Hex)
  return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
}

function New-BallTipCard {
  param($Rows, [string]$Variant)
  $dark = ($Variant -eq 'dark')
  $bg = if ($dark) { '#232329' } else { '#FFFFFF' }
  $line = if ($dark) { '#3B3B47' } else { '#E6E9F0' }
  $fg = if ($dark) { '#F3F4F8' } else { '#15151B' }
  $muted = if ($dark) { '#9FA5B4' } else { '#8A8F9C' }
  $family = New-Object System.Windows.Media.FontFamily([string]"Microsoft YaHei UI")

  $card = New-Object System.Windows.Controls.Border
  $card.CornerRadius = New-Object System.Windows.CornerRadius(14)
  $card.Background = ConvertTo-BallBrush $bg
  $card.BorderBrush = ConvertTo-BallBrush $line
  $card.BorderThickness = New-Object System.Windows.Thickness(1)
  $card.Padding = New-Object System.Windows.Thickness(14, 10, 14, 10)
  $card.MinWidth = 118
  # No DropShadowEffect: inside a tooltip popup the effect needs external margin that
  # the popup itself does not provide, which is what made the card look empty.
  $card.Margin = New-Object System.Windows.Thickness(6, 6, 6, 6)

  $stack = New-Object System.Windows.Controls.StackPanel
  $first = $true
  foreach ($row in @($Rows)) {
    if (-not $row) { continue }
    if (-not $first) {
      $spacer = New-Object System.Windows.Controls.Border
      $spacer.Height = 8
      [void]$stack.Children.Add($spacer)
    }
    $first = $false
    $caption = [string]$row.caption
    if (-not [string]::IsNullOrWhiteSpace($caption)) {
      $cap = New-Object System.Windows.Controls.TextBlock
      $cap.Text = $caption
      $cap.FontFamily = $family
      $cap.FontSize = 10.5
      $cap.Foreground = ConvertTo-BallBrush $muted
      $cap.Margin = New-Object System.Windows.Thickness(0, 0, 0, 2)
      [void]$stack.Children.Add($cap)
    }
    $value = New-Object System.Windows.Controls.TextBlock
    $value.Text = [string]$row.value
    $value.FontFamily = $family
    $value.Foreground = ConvertTo-BallBrush $fg
    if ($row.strong) {
      $value.FontSize = 19
      $value.FontWeight = [System.Windows.FontWeights]::SemiBold
    } else {
      $value.FontSize = 12.5
    }
    [void]$stack.Children.Add($value)
  }

  $card.Child = $stack
  return $card
}

function Update-BallTipCard {
  if (-not $script:ball) { return }
  $tip = $script:ball.ToolTip
  if ($tip -isnot [System.Windows.Controls.ToolTip]) { return }
  $variant = 'light'
  try { $variant = Get-ThemeVariant } catch { }
  $rows = $script:tipRows
  if (-not $rows -or @($rows).Count -eq 0) {
    $rows = @(@{ caption = $null; value = $script:balanceToolTipLabel })
  }
  $tip.Content = New-BallTipCard -Rows $rows -Variant $variant
}

function Set-BallTipRows {
  param($Rows)
  $script:tipRows = @($Rows)
  Update-BallTipCard
}

function Set-BallTipText {
  param([string]$Text)
  Set-BallTipRows -Rows @(@{ caption = $null; value = $Text })
}

function Test-BallWalletNonZero {
  param($Wallet)
  if ($null -eq $Wallet) { return $false }
  $amount = [decimal]0
  $ok = [decimal]::TryParse(
    [string]$Wallet.balance,
    [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [ref]$amount
  )
  if (-not $ok) { return $false }
  return [Math]::Abs($amount) -ge [decimal]0.005
}

function Get-BallBalanceRows {
  param($Result)
  if ($null -eq $Result) { return @(@{ caption = $null; value = '未登录 DeepSeek 账号' }) }
  switch ([string]$Result.status) {
    'ready' {
      $rows = @()
      $rechargeAll = @($Result.value | Where-Object { $_ })
      $recharge = @($rechargeAll | Where-Object { Test-BallWalletNonZero $_ })
      if ($recharge.Count -eq 0) { $recharge = $rechargeAll }
      $primary = if ($recharge.Count -eq 0) {
        '¥0.00'
      } else {
        (($recharge | ForEach-Object { Format-BallWallet $_ }) -join ' / ')
      }
      $rows += @{ caption = '余额'; value = $primary; strong = $true }
      $bonus = @($Result.bonusWallets | Where-Object { Test-BallWalletNonZero $_ })
      if ($bonus.Count -gt 0) {
        $rows += @{ caption = '赠送'; value = (($bonus | ForEach-Object { Format-BallWallet $_ }) -join ' / ') }
      }
      return $rows
    }
    'no-account' { return @(@{ caption = 'DeepSeek'; value = '未登录账号' }) }
    'unavailable' { return @(@{ caption = 'DeepSeek'; value = '当前版本不支持余额查询' }) }
    default { return @(@{ caption = 'DeepSeek'; value = '余额获取失败' }) }
  }
}

function Format-BallWallet {
  param($Wallet)
  $balance = [string]$Wallet.balance
  $amount = [decimal]0
  if ([decimal]::TryParse(
      $balance,
      [System.Globalization.NumberStyles]::Float,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [ref]$amount
    )) {
    $balance = $amount.ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture)
  }
  switch ([string]$Wallet.currency) {
    'CNY' { return '¥' + $balance }
    'USD' { return '$' + $balance }
    default { return ([string]$Wallet.currency + ' ' + $balance) }
  }
}

function Format-BallBalance {
  param($Result)
  if ($null -eq $Result) { return '未登录 DeepSeek 账号' }
  switch ([string]$Result.status) {
    'ready' {
      $lines = @()
      $recharge = @($Result.value | Where-Object { $_ })
      if ($recharge.Count -eq 0) {
        $lines += '余额 ¥0.00'
      } else {
        $lines += ('余额 ' + (($recharge | ForEach-Object { Format-BallWallet $_ }) -join ' / '))
      }
      $bonus = @($Result.bonusWallets | Where-Object { $_ })
      if ($bonus.Count -gt 0) {
        $lines += ('赠送 ' + (($bonus | ForEach-Object { Format-BallWallet $_ }) -join ' / '))
      }
      return ($lines -join "`n")
    }
    'no-account' { return '未登录 DeepSeek 账号' }
    'unavailable' { return '当前版本不支持余额查询' }
    default { return '余额获取失败' }
  }
}

function Stop-BallBalanceRequest {
  $script:balanceGeneration++
  if ($script:balanceTimeoutTimer) {
    try { $script:balanceTimeoutTimer.Stop() } catch { }
    $script:balanceTimeoutTimer = $null
  }
  if ($script:balancePollTimer) {
    try { $script:balancePollTimer.Stop() } catch { }
    $script:balancePollTimer = $null
  }
  if ($script:balanceTempPath) {
    try { Remove-Item -LiteralPath $script:balanceTempPath -Force -ErrorAction SilentlyContinue } catch { }
    $script:balanceTempPath = $null
  }
}

function Start-BallBalanceRequest {
  if ([string]::IsNullOrWhiteSpace($script:balanceUrl)) { return }
  Stop-BallBalanceRequest
  $script:balanceGeneration++
  $script:balanceActiveGeneration = $script:balanceGeneration
  $path = Join-Path $script:root ('balance-' + [Guid]::NewGuid().ToString('N') + '.json')
  $script:balanceTempPath = $path
  try {
    [DshBalanceFetcher]::FetchToFile($script:balanceUrl, $script:balanceToken, $path)
    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval = [TimeSpan]::FromMilliseconds(120)
    $poll.Add_Tick({
      if ($script:balanceGeneration -ne $script:balanceActiveGeneration) { return }
      if (-not (Test-Path -LiteralPath $script:balanceTempPath)) { return }
      if ($script:balancePollTimer) { $script:balancePollTimer.Stop() }
      try {
        $raw = Get-Content -LiteralPath $script:balanceTempPath -Raw -Encoding UTF8
        Remove-Item -LiteralPath $script:balanceTempPath -Force -ErrorAction SilentlyContinue
        if ($raw -like 'ERROR:*') { throw 'balance request failed' }
        $result = $raw | ConvertFrom-Json
        Set-BallTipRows -Rows (Get-BallBalanceRows $result)
      } catch {
        Set-BallTipText '余额获取失败'
      } finally {
        if ($script:balanceTimeoutTimer) {
          try { $script:balanceTimeoutTimer.Stop() } catch { }
          $script:balanceTimeoutTimer = $null
        }
      }
    })
    $script:balancePollTimer = $poll
    $poll.Start()

    $script:balanceTimeoutTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:balanceTimeoutTimer.Interval = [TimeSpan]::FromSeconds(8)
    $script:balanceTimeoutTimer.Add_Tick({
      if ($script:balanceGeneration -ne $script:balanceActiveGeneration) { return }
      Stop-BallBalanceRequest
      Set-BallTipText '余额查询超时'
    })
    $script:balanceTimeoutTimer.Start()
  } catch {
    Set-BallTipText '余额获取失败'
  }
}

$createdNew = $false

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\dsh-quick-chat-ball', [ref]$createdNew)
if (-not $createdNew) {
  Write-BallLog 'another ball is already running'
  exit 0
}
Initialize-WebView2

try {
  Set-Content -LiteralPath $script:pidPath -Value $PID -Encoding ASCII

  $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="84" Height="84"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        ShowInTaskbar="False"
        ShowActivated="False"
        ResizeMode="NoResize"
        WindowStartupLocation="Manual"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Grid x:Name="Root" Background="Transparent">
    <Grid x:Name="Ball" Width="60" Height="60"
          HorizontalAlignment="Center" VerticalAlignment="Center"
          Background="Transparent"
          Cursor="Hand" ToolTip="Desktop Floating Ball">
      <Grid.RenderTransform>
        <ScaleTransform x:Name="BallScale" ScaleX="1" ScaleY="1" />
      </Grid.RenderTransform>
      <Grid.RenderTransformOrigin>0.5,0.5</Grid.RenderTransformOrigin>
      <Ellipse x:Name="BallGradient" Width="60" Height="60" Stroke="#33FFFFFF" StrokeThickness="1">
        <Ellipse.Fill>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#86A8FF" Offset="0" />
            <GradientStop Color="#4D6BFE" Offset="0.52" />
            <GradientStop Color="#2D3FBE" Offset="1" />
          </LinearGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Rectangle x:Name="BallSolid" Width="60" Height="60" Visibility="Collapsed" IsHitTestVisible="False" />
      <Ellipse x:Name="BallInnerRing" Width="55" Height="55" Stroke="#22FFFFFF" StrokeThickness="1" />
      <Viewbox x:Name="BallGlyph" Width="31" Height="31" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Canvas Width="24" Height="24">
          <Path Data="M6.2 3.2 C4.8 3.2 3.6 4.4 3.6 5.8 L3.6 18.4 L8.1 15.2 L18.2 15.2 C19.6 15.2 20.8 14 20.8 12.6 L20.8 5.8 C20.8 4.4 19.6 3.2 18.2 3.2 Z" Fill="#FFFFFFFF" />
          <Path Data="M18 6.2 L18.8 8.2 L20.8 9 L18.8 9.8 L18 11.8 L17.2 9.8 L15.2 9 L17.2 8.2 Z" Fill="#FF4D6BFE" />
        </Canvas>
      </Viewbox>
      <Grid x:Name="BallMedia" Width="60" Height="60" Visibility="Collapsed" IsHitTestVisible="False">
        <Grid.Clip>
          <EllipseGeometry Center="30,30" RadiusX="29" RadiusY="29" />
        </Grid.Clip>
        <Image x:Name="BallImage" Stretch="UniformToFill" Visibility="Collapsed" />
        <MediaElement x:Name="BallVideo" Stretch="UniformToFill" Visibility="Collapsed"
                      LoadedBehavior="Manual" UnloadedBehavior="Manual" IsMuted="True" Volume="0" />
      </Grid>
      <Ellipse x:Name="BallBorder" Width="60" Height="60" Stroke="#33FFFFFF" StrokeThickness="1" IsHitTestVisible="False" />
      <Grid.ContextMenu>
        <ContextMenu x:Name="BallMenu">
          <MenuItem Header="Open desktop ball" />
          <MenuItem Header="Close desktop ball" />
          <Separator />
          <MenuItem Header="Exit floating ball" />
        </ContextMenu>
      </Grid.ContextMenu>
    </Grid>
  </Grid>
</Window>
"@

  $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
  $window = [System.Windows.Markup.XamlReader]::Load($reader)
  $script:window = $window
  $ball = $window.FindName('Ball')
  $script:ball = $ball
  $ballScale = $window.FindName('BallScale')
  $script:ballMedia = $window.FindName('BallMedia')
  $script:ballImage = $window.FindName('BallImage')
  $script:ballVideo = $window.FindName('BallVideo')
  $script:ballGlyph = $window.FindName('BallGlyph')
  $script:ballGradient = $window.FindName('BallGradient')
  $script:ballSolid = $window.FindName('BallSolid')
  $script:ballInnerRing = $window.FindName('BallInnerRing')
  $script:ballBorder = $window.FindName('BallBorder')
  if ($script:ballGradient) { $script:defaultBallFill = $script:ballGradient.Fill }
  $menu = $ball.ContextMenu
  $menuOpen = $menu.Items[0]
  $menuClose = $menu.Items[1]
  $menuExit = $menu.Items[3]

  if ($script:state.labels) {
    if ($script:state.labels.tooltip) { $ball.ToolTip = [string]$script:state.labels.tooltip }
    if ($script:state.labels.open) { $menuOpen.Header = [string]$script:state.labels.open }
    if ($script:state.labels.close) { $menuClose.Header = [string]$script:state.labels.close }
    if ($script:state.labels.exit) { $menuExit.Header = [string]$script:state.labels.exit }
  }

  $script:balanceToolTipLabel = if ($script:state.labels.tooltip) {
    [string]$script:state.labels.tooltip
  } else {
    '点击打开对话'
  }
  $script:tipRows = @(@{ caption = $null; value = $script:balanceToolTipLabel })
  $balanceToolTip = New-Object System.Windows.Controls.ToolTip
  $balanceToolTip.Background = [System.Windows.Media.Brushes]::Transparent
  $balanceToolTip.BorderThickness = New-Object System.Windows.Thickness(0)
  $balanceToolTip.Padding = New-Object System.Windows.Thickness(0)
  $balanceToolTip.HasDropShadow = $false
  # Keep the stock template: a bare ContentPresenter opened as a 0x0 popup here.
  # Anchor on the cursor so a ball docked half outside the screen still shows the card.
  [System.Windows.Controls.ToolTipService]::SetPlacement($ball, [System.Windows.Controls.Primitives.PlacementMode]::Mouse)
  [System.Windows.Controls.ToolTipService]::SetHorizontalOffset($ball, 8)
  [System.Windows.Controls.ToolTipService]::SetVerticalOffset($ball, 8)
  $ball.ToolTip = $balanceToolTip
  Update-BallTipCard
  [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($ball, 450)
  [System.Windows.Controls.ToolTipService]::SetBetweenShowDelay($ball, 150)
  [System.Windows.Controls.ToolTipService]::SetShowDuration($ball, 60000)
  $balanceUrlState = if ($script:balanceUrl) { 'yes' } else { 'no' }
  Write-BallLog ("balance tooltip ready url={0}" -f $balanceUrlState)

  $script:ballVideo.Add_MediaOpened({
    try { $script:ballVideo.Play() } catch { }
  })
  $script:ballVideo.Add_MediaEnded({
    try {
      $script:ballVideo.Position = [TimeSpan]::Zero
      $script:ballVideo.Play()
    } catch { }
  })
  $script:ballVideo.Add_MediaFailed({
    Write-BallLog "ball video failed: $_"
    Set-BallBuiltin
  })

  $window.Title = 'Desktop Floating Ball'
  $window.Add_SourceInitialized({
    try {
      $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
      $handle = $helper.Handle
      $style = [DqcBallNative]::GetWindowLong($handle, [DqcBallNative]::GWL_EXSTYLE)
      [void][DqcBallNative]::SetWindowLong($handle, [DqcBallNative]::GWL_EXSTYLE, ($style -bor [DqcBallNative]::WS_EX_TOOLWINDOW))
    } catch {
      Write-BallLog "toolwindow style failed: $_"
    }
  })
  $window.Add_ContentRendered({
    try {
      $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
      $script:dpiX = [Math]::Max(0.5, $dpi.DpiScaleX)
      $script:dpiY = [Math]::Max(0.5, $dpi.DpiScaleY)
    } catch {
      $script:dpiX = 1.0
      $script:dpiY = 1.0
    }
  })
  $window.Add_Closed({
    try { Stop-BallBalanceRequest } catch { }
    try { if ($script:appearanceTimer) { $script:appearanceTimer.Stop() } } catch { }
    try { if ($script:startupPrewarmTimer) { $script:startupPrewarmTimer.Stop() } } catch { }
    $script:startupPrewarmTimer = $null
    try { Stop-BallMedia } catch { }
    try { Close-ChatWindow } catch { }
    try { Remove-Item -LiteralPath $script:pidPath -Force -ErrorAction SilentlyContinue } catch { }
    try { [void]$mutex.ReleaseMutex() } catch { }
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
  })

  $ball.Add_MouseEnter({
    $ballScale.ScaleX = 1.06
    $ballScale.ScaleY = 1.06
    if (-not [string]::IsNullOrWhiteSpace($script:balanceUrl)) {
      Set-BallTipText '正在查询余额…'
      Start-BallBalanceRequest
    }
    Prewarm-ChatWindow
  })
  $ball.Add_MouseLeave({
    $ballScale.ScaleX = 1.0
    $ballScale.ScaleY = 1.0
    Stop-BallBalanceRequest
  })
  $ball.Add_MouseLeftButtonDown({
    $script:dragging = $true
    $script:moved = $false
    $script:startCursor = [System.Windows.Forms.Cursor]::Position
    $script:startLeft = [double]$window.Left
    $script:startTop = [double]$window.Top
    [void]$ball.CaptureMouse()
  })
  $ball.Add_MouseMove({
    if (-not $script:dragging) { return }
    $current = [System.Windows.Forms.Cursor]::Position
    $dx = ($current.X - $script:startCursor.X) / $script:dpiX
    $dy = ($current.Y - $script:startCursor.Y) / $script:dpiY
    if ([Math]::Abs($dx) + [Math]::Abs($dy) -gt 4) { $script:moved = $true }
    if ($script:moved) {
      $peek = ([double]$script:ballSize / 2) + 12
      $minX = [System.Windows.SystemParameters]::VirtualScreenLeft - $peek
      $minY = [System.Windows.SystemParameters]::VirtualScreenTop - $peek
      $maxX = $minX + [System.Windows.SystemParameters]::VirtualScreenWidth - $window.Width + (2 * $peek)
      $maxY = $minY + [System.Windows.SystemParameters]::VirtualScreenHeight - $window.Height + (2 * $peek)
      $window.Left = [Math]::Max($minX, [Math]::Min($maxX, $script:startLeft + $dx))
      $window.Top = [Math]::Max($minY, [Math]::Min($maxY, $script:startTop + $dy))
    }
  })
  $ball.Add_MouseLeftButtonUp({
    if (-not $script:dragging) { return }
    $script:dragging = $false
    [void]$ball.ReleaseMouseCapture()
    if ($script:moved) {
      Snap-BallToEdge
      Save-Position
    } else {
      # Toggle: a click opens the chat, a click while it is open hides it again.
      # The hidden window keeps its warm WebView, so reopening stays instant.
      $chatForm = $script:chatForm
      if ($chatForm -and -not $chatForm.IsDisposed -and $chatForm.Visible) {
        Write-BallLog 'ball click hide'
        Hide-ChatWindow
        return
      }
      $script:lastBallClickAt = [DateTime]::UtcNow
      Open-Chat
    }
  })

  $menuOpen.Add_Click({ Open-Chat })
  $menuClose.Add_Click({ Hide-ChatWindow })
  $menuExit.Add_Click({
    Close-ChatWindow
    $window.Close()
  })

  $work = [System.Windows.SystemParameters]::WorkArea
  $initialX = $work.Right - 104
  $initialY = $work.Bottom - 124
  try {
    if (Test-Path -LiteralPath $script:positionPath) {
      $saved = Get-Content -LiteralPath $script:positionPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $candidateX = [double]$saved.x
      $candidateY = [double]$saved.y
      # Remap onto the current monitor layout when the saved fraction exists.
      $hasFraction = ($null -ne $saved.fx) -and ($null -ne $saved.fy)
      if ($hasFraction) {
        $scaleX = if ($script:dpiX -gt 0) { $script:dpiX } else { 1 }
        $scaleY = if ($script:dpiY -gt 0) { $script:dpiY } else { 1 }
        $screen = $null
        try {
          $centerX = [int](($candidateX + ($window.Width / 2)) * $scaleX)
          $centerY = [int](($candidateY + ($window.Height / 2)) * $scaleY)
          $screen = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($centerX, $centerY)))
        } catch {
          Write-BallLog "position screen lookup failed: $_"
        }
        if (-not $screen) { $screen = [System.Windows.Forms.Screen]::PrimaryScreen }
        if ($screen) {
          $area = $screen.WorkingArea
          $areaLeft = $area.Left / $scaleX
          $areaTop = $area.Top / $scaleY
          $areaWidth = $area.Width / $scaleX
          $areaHeight = $area.Height / $scaleY
          $candidateX = $areaLeft + ([double]$saved.fx * $areaWidth)
          $candidateY = $areaTop + ([double]$saved.fy * $areaHeight)
          Write-BallLog ("position remapped from fraction {0},{1} on {2} -> {3},{4}" -f $saved.fx, $saved.fy, $screen.DeviceName, [int]$candidateX, [int]$candidateY)
        }
      }
      $peek = ([double]$script:ballSize / 2) + 12
      $minX = [System.Windows.SystemParameters]::VirtualScreenLeft - $peek
      $minY = [System.Windows.SystemParameters]::VirtualScreenTop - $peek
      $maxX = $minX + [System.Windows.SystemParameters]::VirtualScreenWidth - $window.Width + (2 * $peek)
      $maxY = $minY + [System.Windows.SystemParameters]::VirtualScreenHeight - $window.Height + (2 * $peek)
      $initialX = [Math]::Max($minX, [Math]::Min($maxX, $candidateX))
      $initialY = [Math]::Max($minY, [Math]::Min($maxY, $candidateY))
    }
  } catch {
    Write-BallLog "position read failed: $_"
  }
  $window.Left = $initialX
  $window.Top = $initialY
  Write-BallLog ("work area {0},{1} {2}x{3}; initial {4},{5}" -f [int]$work.Left, [int]$work.Top, [int]$work.Width, [int]$work.Height, [int]$initialX, [int]$initialY)

  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
  $timer.Add_Tick({
    if (-not (Get-Process -Id $script:dshPid -ErrorAction SilentlyContinue)) {
      Write-BallLog 'Harness host exited; closing ball'
      Close-ChatWindow
      $window.Close()
      [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
      return
    }
    if (-not (Test-Path -LiteralPath $script:statePath)) {
      Write-BallLog 'state file removed; closing ball'
      Close-ChatWindow
      $window.Close()
      [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
    }
  })
  $timer.Start()

  $window.Show()
  try { Apply-BallAppearance (Read-Appearance) } catch { Write-BallLog "initial ball appearance failed: $_" }
  try {
    $script:appearanceStamp = if (Test-Path -LiteralPath $script:appearancePath) {
      (Get-Item -LiteralPath $script:appearancePath).LastWriteTimeUtc.Ticks.ToString()
    } else { '' }
  } catch { $script:appearanceStamp = '' }
  $script:appearanceTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:appearanceTimer.Interval = [TimeSpan]::FromSeconds(1)
  $script:appearanceTimer.Add_Tick({
    try {
      if (Test-Path -LiteralPath $script:openRequestPath) {
        Remove-Item -LiteralPath $script:openRequestPath -Force -ErrorAction SilentlyContinue
        Write-BallLog 'open request from host'
        Open-Chat
      }
      $stamp = if (Test-Path -LiteralPath $script:appearancePath) {
        (Get-Item -LiteralPath $script:appearancePath).LastWriteTimeUtc.Ticks.ToString()
      } else { '' }
      if ($stamp -ne $script:appearanceStamp) {
        $script:appearanceStamp = $stamp
        Apply-BallAppearance (Read-Appearance)
      }
      $variant = Get-ThemeVariant
      if ($variant -ne $script:themeVariant) {
        $script:themeVariant = $variant
        Write-BallLog ("system theme changed: {0}" -f $variant)
        $appearanceNow = Read-Appearance
        $kindNow = if ($appearanceNow) { [string]$appearanceNow.ballKind } else { 'builtin' }
        if ([string]::IsNullOrWhiteSpace($kindNow) -or $kindNow -eq 'builtin') {
          Apply-BallAppearance $appearanceNow
        }
      }
    } catch { }
  })
  $script:appearanceTimer.Start()
  Write-BallLog "ball shown for host pid $script:dshPid"

  # Start a hidden off-screen chat WebView after the ball settles. The first
  # click then promotes an already-painted window instead of showing a blank
  # white WebView2 surface while DSH boots.
  try {
    $script:startupPrewarmTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:startupPrewarmTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:startupPrewarmTimer.Add_Tick({
      try { $script:startupPrewarmTimer.Stop() } catch { }
      $script:startupPrewarmTimer = $null
      Prewarm-ChatWindow
    })
    $script:startupPrewarmTimer.Start()
  } catch {
    Write-BallLog "startup chat prewarm scheduling failed: $_"
  }

  if ($TestOpen) {
    $script:testOpened = $false
    $testTimer = New-Object System.Windows.Threading.DispatcherTimer
    $testTimer.Interval = [TimeSpan]::FromMilliseconds(900)
    $testTimer.Add_Tick({
      $testTimer.Stop()
      if ($script:testOpened) { return }
      $script:testOpened = $true
      Open-Chat
    })
    $testTimer.Start()
  }

  [System.Windows.Threading.Dispatcher]::Run()
} catch {
  Write-BallLog "FATAL: $_"
  try {
    Close-ChatWindow
  } catch {
  }
  try {
    Remove-Item -LiteralPath $script:pidPath -Force -ErrorAction SilentlyContinue
  } catch {
  }
  try {
    [void]$mutex.ReleaseMutex()
  } catch {
  }
  exit 1
}
