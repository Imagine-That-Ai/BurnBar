# Connect Cursor to refresh usage meters

OpenBurnBar reads a Cursor *product* session so Quotas can refresh Included /
Auto+Composer / API / On-demand from `GET cursor.sh/api/usage-summary`. This is
not Firebase login and not “Sign in to BurnBar with Cursor.” The WorkOS cookie
stays in this Mac’s Keychain (`device_keychain`, account `cursor_cookie` or
`cursor_cookie.<seat>`). Refresh never opens a login window.

Limits are whatever usage-summary returns (cents ÷ 100). Ultra is not hard-coded
to $200 or $400.

## Mac click-through (Emilio)

1. Build and launch the Mac app from this branch.
2. Click the OpenBurnBar menu-bar extra.
3. In **QUOTAS**, find **Cursor**. If the row says **Set up**, click it. If it
   already shows a bar, click the row to expand.
4. Read the subtitle: OpenBurnBar uses this session only to read the usage
   meter. It does not sign you into BurnBar.
5. **Primary — editor session**
   1. Click **Use this Mac’s Cursor app session**.
   2. If only one signed-in install exists, the meter should refresh.
   3. If Cursor and Cursor-2 are both signed in, pick the Ultra seat
      (email / install). Confirm **Add as another seat** if the default meter
      already belongs to a different email. Do not click **Replace this meter**
      unless you intend to drop the first Ultra pool.
6. **Secondary — web login**
   1. Click **Sign in to Cursor**.
   2. Finish Google / GitHub / email on cursor.com in the titled
      **Sign in to Cursor** window (Google popups stay in that window).
   3. The window closes only after `WorkosCursorSessionToken` appears.
   4. Confirm a second seat if prompted.
7. **Tertiary — paste**
   1. Click **Paste WorkosCursorSessionToken**.
   2. Paste `WorkosCursorSessionToken={userId}::{jwt}`.
   3. Click **Save cookie**.
8. Confirm the Cursor row shows Included / Auto+Composer / API / On-demand from
   the live JSON (example Ultra fixture: `$360.63 / $400.00` only when the API
   said `plan.limit: 40000`).
9. Click the popover **Refresh** (clockwise arrow). The login window must **not**
   open. A rejected or expired session stays on the row with
   **Reconnect Cursor to refresh the meter**.

## Multi-seat

One meter seat per Cursor install/email. Connecting Cursor-2 while Cursor is
already connected adds `cursor_cookie.<seat>` and keeps the first cookie. The
dashboard can show two Cursor cards; pools are not summed.
