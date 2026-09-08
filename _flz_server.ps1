param(
  [string]$Root = "C:\Users\maamr\Downloads",
  [int]$Port = 8843
)

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $Root on http://localhost:$Port/"

$mime = @{
  ".html" = "text/html; charset=utf-8"
  ".htm"  = "text/html; charset=utf-8"
  ".js"   = "application/javascript; charset=utf-8"
  ".css"  = "text/css; charset=utf-8"
  ".json" = "application/json; charset=utf-8"
  ".png"  = "image/png"
  ".jpg"  = "image/jpeg"
  ".jpeg" = "image/jpeg"
  ".svg"  = "image/svg+xml"
  ".ico"  = "image/x-icon"
  ".webp" = "image/webp"
}

while ($listener.IsListening) {
  $context = $listener.GetContext()
  $request = $context.Request
  $response = $context.Response
  try {
    $path = $request.Url.AbsolutePath
    if ($path -eq "/") { $path = "/index.html" }
    $filePath = Join-Path $Root ($path.TrimStart("/"))
    if (Test-Path $filePath -PathType Leaf) {
      $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
      $contentType = $mime[$ext]
      if (-not $contentType) { $contentType = "application/octet-stream" }
      $bytes = [System.IO.File]::ReadAllBytes($filePath)
      $response.ContentType = $contentType
      $response.ContentLength64 = $bytes.Length
      $response.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      $response.StatusCode = 404
      $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $path")
      $response.OutputStream.Write($msg, 0, $msg.Length)
    }
  } catch {
    $response.StatusCode = 500
  } finally {
    $response.OutputStream.Close()
  }
}
