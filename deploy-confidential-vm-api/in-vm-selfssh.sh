#!/usr/bin/env bash
# Self-loop SSH for the dstack and SkyPilot tests: a key that lets the VM reach itself as `ubuntu`
# over SSH. In your own setup the dstack server or the SkyPilot client is your machine and uses the
# key you registered on your account; this step exists only because the tests run both ends in one VM.
#
# Run as a --pre-script by deploy_and_attest.py. Prints every diagnostic, never stops at the first
# refusal, and writes $HOME/selfssh.env (SELF_SSH_PORT, SELF_SSH_KEY) once a connection works:
#   1. ~/.ssh and authorized_keys owned by ubuntu (700 / 600), key appended after a newline check;
#   2. the key added to every AuthorizedKeysFile sshd really reads for a loopback login;
#   3. a second sshd on 127.0.0.1:2222 with a minimal configuration of its own.
#
# History: on 2026-10-23 ~/.ssh was root:root 755 on this image, and a key appended to
# authorized_keys was refused for ubuntu@127.0.0.1 ("Permission denied (publickey)").
set -uo pipefail
cd "$HOME"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
U=ubuntu
KEY="$HOME/fleet_ed25519"
AK="$HOME/.ssh/authorized_keys"
SSHD=/usr/sbin/sshd
rm -f selfssh.env
PORT=""

log "== diagnostics before any change"
ls -ld "$HOME" "$HOME/.ssh" "$AK" 2>&1
printf 'authorized_keys: %s line(s), last byte:' "$(sudo wc -l < "$AK" 2>/dev/null || echo '?')"
sudo tail -c1 "$AK" 2>/dev/null | od -An -c
echo "sshd -T for a loopback login (user=$U, addr=127.0.0.1):"
sudo $SSHD -T -C "user=$U,host=localhost,addr=127.0.0.1" 2>&1 \
  | grep -iE "^(authorizedkeysfile|authorizedkeyscommand|authorizedkeyscommanduser|pubkeyauthentication|strictmodes|allowtcpforwarding|allowusers|allowgroups|denyusers|listenaddress|port|usepam) " | sed 's/^/   /'
echo "Match blocks and AuthorizedKeys lines in the sshd configuration:"
sudo grep -rniE "^\s*(match|authorizedkeys)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/   /' || true

log "== 1. ~/.ssh owned by $U (700), authorized_keys owned by $U (600), content kept"
# Fixed in place rather than deleted and recreated: authorized_keys carries the key this very session
# logged in with, and every later step of the run opens a new SSH connection with it.
sudo chown "$U:$U" "$HOME/.ssh" && sudo chmod 700 "$HOME/.ssh"
sudo touch "$AK" && sudo chown "$U:$U" "$AK" && sudo chmod 600 "$AK"
ls -ld "$HOME/.ssh" "$AK"
[ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -C "selfloop" -f "$KEY" -q
ssh-keygen -lf "$KEY.pub"

add_key() {  # add_key <file>: appends the public key, after a newline when the file lacks a final one
  local f=$1
  if sudo grep -qF "$(cut -d' ' -f2 "$KEY.pub")" "$f" 2>/dev/null; then log "key already in $f"; return 0; fi
  if sudo test -s "$f" && [ -n "$(sudo tail -c1 "$f")" ]; then
    log "$f does not end with a newline: adding one first"
    echo | sudo tee -a "$f" >/dev/null
  fi
  sudo tee -a "$f" < "$KEY.pub" >/dev/null && log "key appended to $f"
}
try() {  # try <label> <port>: ssh to ubuntu@127.0.0.1, checks passwordless sudo too
  local out
  # -n and </dev/null: this script is fed to `bash -s` over stdin; on 2026-10-23 (third run) an ssh
  # without them read the rest of the script, which then ended right after a successful test.
  out=$(ssh -n -i "$KEY" -p "$2" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$HOME/known_hosts_self" -o ConnectTimeout=10 "$U@127.0.0.1" \
        'echo connected; sudo -n true && echo passwordless-sudo' 2>&1 </dev/null)
  echo "$out" | sed 's/^/   /'
  if echo "$out" | grep -qx connected; then log "$1: OK"; return 0; fi
  log "$1: REFUSED. Last sshd journal lines:"
  sudo journalctl -u ssh -u sshd -n 20 --no-pager 2>&1 | cut -c1-220 | sed 's/^/   /'
  return 1
}

add_key "$AK"
if try "ssh -o BatchMode=yes -i fleet_ed25519 ubuntu@127.0.0.1 (port 22, ~/.ssh/authorized_keys)" 22; then PORT=22; fi

if [ -z "$PORT" ]; then
  log "== 2. every AuthorizedKeysFile sshd reads for a loopback login"
  for raw in $(sudo $SSHD -T -C "user=$U,host=localhost,addr=127.0.0.1" 2>/dev/null | awk 'tolower($1)=="authorizedkeysfile"{for(i=2;i<=NF;i++)print $i}'); do
    f=${raw//%u/$U}; f=${f//%h/$HOME}; f=${f//%%/%}
    case "$f" in /*) ;; *) f="$HOME/$f" ;; esac
    [ "$f" = "$AK" ] && continue
    [ "$f" = "none" ] && { log "AuthorizedKeysFile none"; continue; }
    log "sshd also reads $f"
    sudo mkdir -p "$(dirname "$f")"
    add_key "$f"
  done
  if sudo $SSHD -T -C "user=$U,host=localhost,addr=127.0.0.1" 2>/dev/null | grep -qiE "^authorizedkeyscommand [^n]"; then
    log "an AuthorizedKeysCommand is configured: keys may come from it, not from files"
  fi
  try "same test after step 2 (port 22)" 22 && PORT=22
fi

if [ -z "$PORT" ]; then
  log "== 3. fallback: a second sshd on 127.0.0.1:2222 with its own minimal configuration"
  sudo install -m 644 -o root -g root "$KEY.pub" /etc/ssh/selfloop_authorized_keys
  sudo tee /etc/ssh/sshd_selfloop_config >/dev/null <<'CFG'
Port 2222
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile /etc/ssh/selfloop_authorized_keys
AllowTcpForwarding yes
UsePAM yes
PidFile /run/sshd_selfloop.pid
Subsystem sftp /usr/lib/openssh/sftp-server
CFG
  sudo mkdir -p /run/sshd
  if sudo $SSHD -t -f /etc/ssh/sshd_selfloop_config; then
    sudo $SSHD -f /etc/ssh/sshd_selfloop_config -E /tmp/sshd_selfloop.log
    sleep 1
    if try "ssh -i fleet_ed25519 ubuntu@127.0.0.1 -p 2222 (second sshd)" 2222; then PORT=2222
    else log "second sshd log:"; sudo tail -20 /tmp/sshd_selfloop.log | sed 's/^/   /'; fi
  else
    log "the minimal sshd configuration did not pass sshd -t"
  fi
fi

if [ -n "$PORT" ]; then
  printf 'SELF_SSH_PORT=%s\nSELF_SSH_KEY=%s\n' "$PORT" "$KEY" > selfssh.env
  log "self-loop SSH ready: port $PORT, key $KEY"
  exit 0
fi
log "self-loop SSH: every attempt refused (dstack and SkyPilot will report NOT EXECUTED)"
exit 1
