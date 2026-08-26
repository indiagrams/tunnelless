# Privacy Policy — Tunnelless

**Last updated:** 26 August 2026
**Provider:** Indiagram LLC

## Summary

Tunnelless collects nothing. There is no analytics SDK, no crash reporter, no
advertising identifier, and no account system of our own. Indiagram LLC operates
no servers that this app talks to.

## What the app stores

Tunnelless runs a userspace Tailscale node inside the app process. That node
keeps a state directory — node keys and the record that the device is
authorized on your network — inside the app's own container on your device.

This state:

- never leaves your device,
- is not readable by other apps,
- is deleted when you sign out, and
- is removed with the app when you delete it.

## What the app sends, and to whom

Signing in opens Tailscale's own web login. Your Tailscale credentials are
entered on Tailscale's site and are never seen by Tunnelless or by Indiagram
LLC.

Once connected, the node communicates with Tailscale's coordination server,
Tailscale's DERP relays, and the peers on your own network — exactly as any
Tailscale client does. That traffic is governed by Tailscale's own privacy
policy, not this one:

<https://tailscale.com/privacy-policy>

Traffic you send through the app's local SOCKS5 proxy goes to the machines on
your own network. It is not proxied through, logged by, or visible to Indiagram
LLC.

## Data collection disclosures

The app ships an Apple Privacy Manifest declaring no tracking, no collected
data types, and no required-reason API usage. This policy matches that
declaration.

| Apple category | Status |
|---|---|
| Data used to track you | None |
| Data linked to you | None |
| Data not linked to you | None |

## Children

Tunnelless is a networking utility and is not directed at children. It collects
no personal information from anyone, including children.

## Changes

Material changes to this policy will be published in this file, with the date
above updated. The file's history is public in the repository.

## Contact

Questions about this policy: <jpraju@gmail.com>

Issues and bug reports: <https://github.com/indiagrams/tunnelless/issues>
