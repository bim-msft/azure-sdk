param (
  # url to verify links. Can either be a http address or a local file request. Local file paths support md and html files.
  [string] $url,
  # file that contains a set of links to ignore when verifying
  [string] $ignoreLinksFile = "$PSScriptRoot/ignore-links.txt",
  # switch that will enable devops specific logging for warnings
  [switch] $devOpsLogging = $false,
  # check the links recurisvely based on recursivePattern
  [switch] $recursive = $true,
  # recusiving check links for all links verified that begin with this baseUrl, defaults to the folder the url is contained in
  [string] $baseUrl = "",
  # path to the root of the site for resolving rooted relative links, defaults to host root for http and file directory for local files
  [string] $rootUrl = "",
  # list of http status codes count as broken links. Defaults to 404. 
  [array] $errorStatusCodes = @(404)
)

$ProgressPreference = "SilentlyContinue"; # Disable invoke-webrequest progress dialog

function LogWarning
{
  if ($devOpsLogging)
  {
    Write-Host "##vso[task.LogIssue type=warning;]$args"
  }
  else
  {
    Write-Warning "$args"
  }
}

function ResolveUri ([System.Uri]$referralUri, [string]$link)
{
  $linkUri = [System.Uri]$link;

  if (!$linkUri.IsAbsoluteUri) {
    # For rooted paths resolve from the baseUrl
    if ($link.StartsWith("/")) {
      $linkUri = new-object System.Uri([System.Uri]$rootUrl, ".$link");
    }
    else {
      $linkUri = new-object System.Uri($referralUri, $link);
    }
  }

  $linkUri = [System.Uri]$linkUri.GetComponents([System.UriComponents]::HttpRequestUrl, [System.UriFormat]::SafeUnescaped)
  Write-Verbose "ResolvedUri $link to $linkUri"

  # If the link is not a web request, like mailto, skip it.
  if (!$linkUri.Scheme.StartsWith("http") -and !$linkUri.IsFile) {
    Write-Verbose "Skipping $linkUri because it is not http or file based."
    return $null
  }

  if ($null -ne $ignoreLinks -and $ignoreLinks.Contains($link)) {
    Write-Verbose "Ignoring invalid link $linkUri because it is in the ignore file."
    return $null
  }

  return $linkUri;
}

function ParseLinks([string]$baseUri, [string]$htmlContent)
{
  $hrefRegex = "<a[^>]+href\s*=\s*[""']?(?<href>[^""'\s]*)[""']?"
  $regexOptions = [System.Text.RegularExpressions.RegexOptions]"Singleline, IgnoreCase";

  $hrefs = [RegEx]::Matches($htmlContent, $hrefRegex, $regexOptions);

  Write-Verbose "Found $($hrefs.Count) raw href's in page $baseUri";
  $links = $hrefs | ForEach-Object { ResolveUri $baseUri $_.Groups["href"].Value } | Sort-Object -Unique

  return $links
}

function CheckLink ([System.Uri]$linkUri)
{
  if ($checkedLinks.ContainsKey($linkUri)) { return }

  Write-Verbose "Checking link $linkUri..."
  if ($linkUri.IsFile) {
    if (!(Test-Path $linkUri.LocalPath)) {
      LogWarning "Link to file does not exist $($linkUri.LocalPath)"
      $script:badLinks += $linkUri
    }
  }
  else {
    try {
      $response = Invoke-WebRequest -Uri $linkUri
      $statusCode = $response.StatusCode
      if ($statusCode -ne 200) {
        Write-Host "[$statusCode] while requesting $linkUri"
      }
    }
    catch {
      $statusCode = $_.Exception.Response.StatusCode.value__

      if ($statusCode -in $errorStatusCodes) {
        LogWarning "[$statusCode] broken link $linkUri"
        $script:badLinks += $linkUri 
      }
      else {
        if ($null -ne $statusCode) {
          Write-Host "[$statusCode] while requesting $linkUri"
        }
        else {
          Write-Host "Exception while requesting $linkUri"
          Write-Host $_.Exception.ToString()
        }
      }
    }
  }
  $checkedLinks[$linkUri] = $true;
}

function GetLinks([System.Uri]$pageUri)
{
  if ($pageUri.Scheme.StartsWith("http")) {
    try {
      $response = Invoke-WebRequest -Uri $pageUri
      $content = $response.Content
    }
    catch {
      $statusCode = $_.Exception.Response.StatusCode.value__
      Write-Error "Invalid page [$statusCode] $pageUri"
    }
  }
  elseif ($pageUri.IsFile -and (Test-Path $pageUri.LocalPath)) {
    $file = $pageUri.LocalPath
    if ($file.EndsWith(".md")) {
      $content = (ConvertFrom-MarkDown $file).html
    }
    elseif ($file.EndsWith(".html")) {
      $content = Get-Content $file
    }
    else {
      if (Test-Path ($file + "index.html")) {
        $content = Get-Content ($file + "index.html")
      }
      else {
        Write-Error "Don't know how to process file $pageUri"
      }
    }
  }
  else {
    Write-Error "Don't know how to process uri $pageUri"
  }

  $links = ParseLinks $pageUri $content

  #$links | Foreach-Object { Write-Host $_ }

  return $links;
}

if ($url -eq "")
{
  Write-Host "Usage $($MyInvocation.MyCommand.Name) <url>";
  exit;
}

if ($PSVersionTable.PSVersion.Major -lt 6)
{
  LogWarning "Some web requests will not work in versions of PS earlier then 6. You are running version $($PSVersionTable.PSVersion)."
}

$badLinks = @();
$ignoreLinks = @();
if (Test-Path $ignoreLinksFile)
{
  $ignoreLinks = [Array](Get-Content $ignoreLinksFile | ForEach-Object { ($_ -replace "#.*", "").Trim() } | Where-Object { $_ -ne "" })
}

$checkedPages = @{};
$checkedLinks = @{};
$pageUrisToCheck = new-object System.Collections.Queue

if (Test-Path $url) {
  $url = "file://" + (Resolve-Path $url).ToString();
}

$uri = [System.Uri]$url;

if ($baseUrl -eq "") {
  # for base url default to containing directory
  $baseUrl = (new-object System.Uri($uri, ".")).ToString();
}

if ($rootUrl -eq "") {
  if ($uri.IsFile) { 
    # for files default to the containing directory
    $rootUrl = $baseUrl;
  }
  else {
    # for http links default to the root path
    $rootUrl = new-object System.Uri($uri, "/");
  }
}

Write-Host "Verifying links for $uri"
if ($recursive) {
  Write-Host "and recursively verifying links on pages that start with $baseUrl"
}

$pageUrisToCheck.Enqueue($uri);

while ($pageUrisToCheck.Count -ne 0)
{
  $pageUri = $pageUrisToCheck.Dequeue();
  if ($checkedPages.ContainsKey($pageUri)) { continue }
  $checkedPages[$pageUri] = $true;

  $linkUris = GetLinks $pageUri
  Write-Host "Found $($linkUris.Count) links on page $pageUri";
  
  foreach ($linkUri in $linkUris) {
    CheckLink $linkUri
    if ($recursive) {
      if ($linkUri.ToString().StartsWith($baseUrl) -and !$checkedPages.ContainsKey($linkUri)) {
        $pageUrisToCheck.Enqueue($linkUri);
      }
    }
  }
}

Write-Host "Found $($checkedLinks.Count) links with $($badLinks.Count) broken"
$badLinks | ForEach-Object { Write-Host "  $_" }

exit $badLinks.Count