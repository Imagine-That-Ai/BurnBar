type HeaderWriter = {
  setHeader(name: string, value: string): unknown;
};

const PUBLIC_JSON_SECURITY_HEADERS: ReadonlyArray<readonly [string, string]> = [
  ["Cache-Control", "no-store"],
  ["Content-Security-Policy", "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"],
  ["Permissions-Policy", "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"],
  ["Referrer-Policy", "no-referrer"],
  ["X-Content-Type-Options", "nosniff"],
];

export function setPublicJsonSecurityHeaders(res: HeaderWriter): void {
  for (const [name, value] of PUBLIC_JSON_SECURITY_HEADERS) {
    res.setHeader(name, value);
  }
}
