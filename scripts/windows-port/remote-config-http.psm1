Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-RemoteConfigHttpClient {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip
    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    return $client
}

function Get-RemoteConfigETag([System.Net.Http.HttpResponseMessage] $Response) {
    if ($null -ne $Response.Headers.ETag) {
        $typedValue = [string]$Response.Headers.ETag.Tag
        if (-not [string]::IsNullOrWhiteSpace($typedValue)) {
            return $typedValue
        }
    }

    # Firebase currently emits an unquoted ETag. Use HttpHeaders' structured,
    # non-validating view when the RFC parser declines to materialize it.
    foreach ($header in $Response.Headers.NonValidated) {
        if ([string]::Equals([string]$header.Key, 'ETag', [StringComparison]::OrdinalIgnoreCase)) {
            $rawValue = [string]$header.Value
            if (-not [string]::IsNullOrWhiteSpace($rawValue)) {
                return $rawValue.Trim()
            }
        }
    }
    return $null
}

function Invoke-RemoteConfigRequest {
    param(
        [Parameter(Mandatory = $true)] [System.Net.Http.HttpClient] $Client,
        [Parameter(Mandatory = $true)] [System.Net.Http.HttpMethod] $Method,
        [Parameter(Mandatory = $true)] [uri] $Uri,
        [Parameter(Mandatory = $true)] [string] $AccessToken,
        [Parameter(Mandatory = $true)] [string] $QuotaProject,
        [string] $IfMatch,
        [string] $Body
    )

    $request = [System.Net.Http.HttpRequestMessage]::new($Method, $Uri)
    try {
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
            'Bearer',
            $AccessToken
        )
        if (-not $request.Headers.TryAddWithoutValidation('x-goog-user-project', $QuotaProject)) {
            throw 'Unable to set the staging quota-project header.'
        }
        if (-not $request.Headers.TryAddWithoutValidation('Accept-Encoding', 'gzip')) {
            throw 'Unable to request the Remote Config gzip response required for ETag concurrency.'
        }
        if (-not [string]::IsNullOrWhiteSpace($IfMatch) -and
            -not $request.Headers.TryAddWithoutValidation('If-Match', $IfMatch)) {
            throw 'Unable to set the exact Remote Config concurrency ETag.'
        }
        if ($null -ne $Body) {
            $request.Content = [System.Net.Http.StringContent]::new(
                $Body,
                [Text.Encoding]::UTF8,
                'application/json'
            )
        }

        $response = $Client.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        try {
            $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $response.EnsureSuccessStatusCode() | Out-Null
            return [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Content = $content
                ETag = Get-RemoteConfigETag $response
            }
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $request.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Get-RemoteConfigETag',
    'Invoke-RemoteConfigRequest',
    'New-RemoteConfigHttpClient'
)
