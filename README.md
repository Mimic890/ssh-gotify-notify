# ssh-gotify-notify

Know who logged into your servers, from where, and for how long.

Hooks into PAM via `pam_exec` and pushes a notification to your
[Gotify](https://gotify.net) server on session open and close.

**Login notification includes:** username, source IP, reverse DNS,
city/country/ASN (via ipinfo.io), auth method (publickey/password),
TTY, timestamp, host uptime.

**Logout notification includes:** username, source IP, session duration.

## Install

### Debian / Ubuntu
```bash
curl -fsSLO https://raw.githubusercontent.com/USER/sshgotify/main/install-ssh-notify.sh
sudo bash install-ssh-notify.sh
```
Prompts for your Gotify URL and application token, installs dependencies,
sends two test messages, and only then touches PAM. If Gotify doesn't
respond, nothing is modified.

### NixOS
```nix
imports = [ ./ssh-notify.nix ];

services.sshNotify = {
  enable = true;
  url = "https://gotify.example.com";
  tokenFile = config.sops.secrets.gotify-ssh-token.path;
};
```

## Notes

- Notifications fire on **successful** logins only. For failed attempts
  use fail2ban or CrowdSec with a Gotify action — otherwise an
  internet-facing port 22 will flood your phone.
- The PAM rule is `optional`, so a broken script cannot lock you out.
- Geolocation is optional (`--no-geo`). ipinfo.io allows 1000 lookups
  per month without a token.
- Use a dedicated Gotify application so SSH alerts can be muted
  separately from your other services.
