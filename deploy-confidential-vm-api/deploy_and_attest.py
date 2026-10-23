#!/usr/bin/env python3
"""Deploy ONE Confidential VM through the VoltageGPU public API, wait for SSH, run nvidia-smi and the
published two-proofs script inside it (Intel TDX quote + NVIDIA GPU attestation, on a challenge drawn
HERE), copy the bundle out, stop the VM in a finally block, read the billing, then verify the bundle
offline with voltage-verify.

Guards, in the spirit of VoltageGPU's own weekly proof run (scripts/proof-run in the site repository):
never a second VM (the account must have no confidential pod running), a hard cap on VM lifetime
(--max-minutes, default 30), a watchdog that stops the VM five minutes before the cap, every wait ends
before that deadline, the stop is retried and confirmed through the API. The price comes from the
API, never from this file. The deploy answer carries a one-time sudo password: it is never logged.

Standard library only. Needs: an OpenSSH client, and voltage-verify >= 0.2.3 in the same Python.

  export VOLTAGEGPU_VOLT_API_KEY=volt_...   # GPU Pods key, https://voltagegpu.com/api-keys
  python deploy_and_attest.py --check                           # guards only, nothing rented
  python deploy_and_attest.py --run --ssh-key ~/.ssh/id_ed25519 [--sku rtx6000b-small]
         [--pre-script a.sh ...] [--script b.sh[:seconds] ...] [--background-script c.sh ...] [--max-minutes 30]
  python deploy_and_attest.py --reap                            # stop a VM a killed run left behind
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

API = "https://api.voltagegpu.com"
SITE = "https://voltagegpu.com"
VM_SCRIPT_URL = f"{SITE}/blog/two-proofs/evidence/two-proofs-in-the-vm.sh"
MIN_VERIFIER = (0, 2, 3)
HWMODEL = {"rtx6000b-small": "GB20X", "h100-small": "GH100", "h200-small": "GH100"}
SSH = shutil.which("ssh") or "C:/Windows/System32/OpenSSH/ssh.exe"
HERE = pathlib.Path(__file__).resolve().parent
RUNS = HERE / "runs"


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def redact(obj: object) -> object:
    """The deploy answer holds the VM's one-time sudo password: it never reaches a log or a file."""
    if isinstance(obj, dict):
        return {k: ("<not logged>" if k == "sudoPassword" else redact(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v) for v in obj]
    return obj


# ── public API ────────────────────────────────────────────────────────────────
class Api:
    def __init__(self, key: str) -> None:
        self.key = key

    def call(self, method: str, path: str, body: object | None = None) -> tuple[int, object]:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(f"{API}{path}", data=data, method=method, headers={
            "X-API-Key": self.key, "Content-Type": "application/json", "User-Agent": "voltage-cookbook/1"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, raw.decode(errors="replace")
        except (urllib.error.URLError, TimeoutError) as e:
            return 0, {"error": str(e)}


# ── SSH, argument vectors only, remote scripts on stdin ───────────────────────
class Target:
    def __init__(self, host: str, port: int, key: str, known_hosts: pathlib.Path) -> None:
        self.host, self.port, self.key, self.known_hosts = host, port, key, known_hosts

    def args(self, command: str) -> list[str]:
        return [SSH, "-i", self.key, "-p", str(self.port), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={self.known_hosts}",
                "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
                f"ubuntu@{self.host}", command]

    def run(self, command: str, stdin: str | None = None, timeout: float = 60) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(self.args(command), input=stdin.encode() if stdin else None, capture_output=True,
                                  timeout=max(1, timeout))
        except subprocess.TimeoutExpired as e:
            return subprocess.CompletedProcess(e.cmd, 124, e.stdout or b"", (e.stderr or b"") + b"\n(timed out)")


def wait_ssh(target: Target, deadline: float) -> bool:
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        r = target.run("true", timeout=min(25, deadline - time.time()))
        if r.returncode == 0:
            return True
        if attempt == 1 or attempt % 4 == 0:
            log(f"   sshd not answering yet ({r.stderr.decode(errors='replace').strip().splitlines()[-1:] or r.returncode})")
        time.sleep(10)
    return False


# ── guards ────────────────────────────────────────────────────────────────────
def verifier_version() -> tuple[int, ...] | None:
    r = subprocess.run([sys.executable, "-m", "voltage_verify", "--version"], capture_output=True, text=True)
    parts = r.stdout.strip().split()
    return tuple(int(x) for x in parts[-1].split(".")) if r.returncode == 0 and len(parts) == 2 else None


def guards(api: Api, sku: str) -> dict:
    """Everything that must be true before a cent is spent. Fails closed on anything unreadable."""
    st, bal = api.call("GET", "/api/volt/balance")
    if st != 200:
        raise SystemExit(f"GET /api/volt/balance -> HTTP {st} {bal}")
    st, pods = api.call("GET", "/api/volt/pods")
    if st != 200 or not isinstance(pods, list):
        raise SystemExit(f"GET /api/volt/pods -> HTTP {st}: cannot tell whether a VM is already running")
    confidential = [p for p in pods if p.get("provider") == "confidential"]
    if confidential:
        raise SystemExit(f"{len(confidential)} confidential VM(s) already running on this account: never a second one")
    st, tiers = api.call("GET", "/api/confidential/vm/tiers")
    tier = next((t for t in (tiers.get("tiers", []) if st == 200 else []) if t.get("resourceName") == sku), None)
    if not tier:
        raise SystemExit(f"{sku} is not listed by GET /api/confidential/vm/tiers (HTTP {st})")
    if not tier.get("available", 0) > 0:
        raise SystemExit(f"{sku}: 0 available right now")
    if tier.get("attestation", {}).get("verified") is not True:
        raise SystemExit(f"{sku}: GPU attestation not verified on this tier, pick another")
    price = float(tier["pricePerHour"])
    if not bal["balance"] >= price:
        raise SystemExit(f"balance {bal['balance']} $ is under one prepaid hour ({price} $): top up first")
    v = verifier_version()
    if not v or v < MIN_VERIFIER:
        raise SystemExit(f"voltage-verify >= {'.'.join(map(str, MIN_VERIFIER))} is needed here (found {v})")
    if not pathlib.Path(SSH).exists() and not shutil.which("ssh"):
        raise SystemExit("no ssh client found")
    log(f"balance {bal['balance']:.2f} $, {sku} {price} $/h, {tier['available']} available, "
        f"attestation verified {tier['attestation'].get('verifiedOn', '')}, voltage-verify {'.'.join(map(str, v))}, "
        f"0 confidential VM running")
    return {"balance_before": bal["balance"], "price": price, "tier": tier}


def ensure_ssh_key(api: Api, key_path: str) -> str:
    pub = pathlib.Path(f"{key_path}.pub").read_text().strip()
    st, keys = api.call("GET", "/api/volt/ssh-keys")
    items = keys if isinstance(keys, list) else keys.get("data", [])
    if any((k.get("publicKey") or "").strip() == pub for k in items):
        return "already registered"
    st, created = api.call("POST", "/api/volt/ssh-keys", {"name": f"cookbook-{time.strftime('%Y%m%d')}", "public_key": pub})
    if st != 201:
        raise SystemExit(f"POST /api/volt/ssh-keys -> HTTP {st} {created}")
    return f"registered (id {created.get('id')})"


# ── the run ───────────────────────────────────────────────────────────────────
class Run:
    def __init__(self, api: Api, args: argparse.Namespace, facts: dict) -> None:
        self.api, self.args, self.facts = api, args, facts
        self.dir = RUNS / time.strftime("%Y-%m-%d-%H-%M-%S")
        self.dir.mkdir(parents=True)
        self.state = self.dir / "state.json"
        self.pod_id: str | None = None
        self.workload: str | None = None
        self.deployed_at = 0.0
        self.stopped: dict | None = None
        self.lock = threading.Lock()
        self.max_s = args.max_minutes * 60
        self.soft_s = self.max_s - 5 * 60  # watchdog; every wait ends 90 s before it

    def left(self) -> float:
        return max(0.0, self.deployed_at + self.soft_s - 90 - time.time())

    def save(self, **extra: object) -> None:
        self.state.write_text(json.dumps({"podId": self.pod_id, "workloadUid": self.workload,
                                          "deployedAt": self.deployed_at, "stopped": self.stopped, **extra}, indent=2))

    def stop_once(self) -> dict:
        """POST /stop, retried, then DELETE as a fallback; idempotent, one caller at a time.
        A failed stop is NOT recorded as done, so the next caller (or --reap) tries again."""
        with self.lock:
            if self.stopped:
                return self.stopped
            for wait in (5, 15, 0):
                st, body = self.api.call("POST", f"/api/volt/pods/{self.pod_id}/stop")
                log(f"   POST /api/volt/pods/{{id}}/stop -> HTTP {st}")
                if st == 200:
                    self.stopped = {"via": "stop", "ok": True, "at": time.time(), "body": redact(body)}
                    break
                if st == 404:
                    break
                time.sleep(wait)
            if not self.stopped:
                st, body = self.api.call("DELETE", f"/api/volt/pods/{self.pod_id}")
                log(f"   DELETE /api/volt/pods/{{id}} -> HTTP {st}")
                if st == 200:
                    self.stopped = {"via": "delete", "ok": True, "at": time.time(), "body": redact(body)}
            self.save()
            return self.stopped or {"via": "none", "ok": False, "at": time.time()}

    def confirm_gone(self) -> bool:
        for _ in range(8):
            st, pods = self.api.call("GET", "/api/volt/pods")
            if st == 200 and isinstance(pods, list) and not any(p.get("id") in (self.workload, self.pod_id) for p in pods):
                return True
            time.sleep(10)
        return False

    def deploy(self) -> None:
        name = f"cookbook-{time.strftime('%Y%m%d')}"
        body = {"provider": "confidential", "name": name, "resource_name": self.args.sku, "hardstop_hours": 1}
        log(f"POST /api/volt/pods {json.dumps(body)}")
        self.deployed_at = time.time()
        st, ans = self.api.call("POST", "/api/volt/pods", body)
        if st != 200 or not isinstance(ans, dict) or not ans.get("podId"):
            raise SystemExit(f"deploy refused: HTTP {st} {json.dumps(redact(ans))[:300]}")
        self.pod_id, self.workload = ans["podId"], ans["workloadUid"]
        self.save(deployAnswer=redact(ans))
        log(f"   HTTP {st}: pod {self.pod_id}, workload {self.workload}, {ans.get('hourlyPrice')} $/h, "
            f"site hard stop at {ans.get('hardStopAt')}, sudo password: returned once, not logged")

    def wait_address(self) -> Target:
        while self.left() > 5 * 60:
            time.sleep(15)
            st, pods = self.api.call("GET", "/api/volt/pods")
            pod = next((p for p in (pods if isinstance(pods, list) else []) if p.get("id") == self.workload), None)
            log(f"   {int(time.time() - self.deployed_at)} s  provider_status {pod and pod.get('provider_status')}  "
                f"ssh_ready {pod and pod.get('ssh_ready')}")
            if pod and pod.get("ssh_ready") and pod.get("ssh_host") and pod.get("ssh_port"):
                return Target(str(pod["ssh_host"]), int(pod["ssh_port"]), self.args.ssh_key, self.dir / "known_hosts")
        raise SystemExit("the VM never became reachable")

    def run_script(self, target: Target, path: pathlib.Path, env: dict[str, str], budget: float) -> int:
        script = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        env_s = " ".join(f"{k}={v}" for k, v in env.items())
        log(f"   >> {path.name} (budget {int(budget)} s)")
        r = target.run(f"{env_s} bash -s", stdin=script, timeout=budget + 30)
        (self.dir / f"{path.stem}.log").write_bytes(r.stdout + (b"\n--- stderr ---\n" + r.stderr if r.stderr else b""))
        last = r.stdout.decode(errors="replace").strip().splitlines()[-1:] or [""]
        log(f"   << {path.name} exit {r.returncode}, {len(r.stdout.splitlines())} lines, last: {last[0][:100]}")
        return r.returncode

    def copy_out(self, target: Target, names: list[str]) -> None:
        for name in names:
            r = target.run(f"cat -- {name}", timeout=min(60, self.left()))
            if r.returncode != 0:
                raise RuntimeError(f"could not copy {name} out of the VM")
            (self.dir / name).write_bytes(r.stdout)

    def start_background(self, target: Target, path: pathlib.Path) -> None:
        """Copies a script into the VM and starts it detached; <stem>.done holds its exit code at the end."""
        script = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        target.run(f"cat > {path.name}", stdin=script, timeout=30)
        budget = int(self.left() - 150)
        cmd = (f"nohup bash -c 'BUDGET_SECONDS={budget} bash {path.name} > {path.stem}.log 2>&1; "
               f"echo $? > {path.stem}.done' </dev/null >/dev/null 2>&1 & echo started")
        r = target.run(cmd, timeout=30)
        log(f"   background: {path.name} {r.stdout.decode().strip() or r.returncode} (budget {budget} s)")

    def collect_background(self, target: Target, paths: list[pathlib.Path]) -> None:
        """Waits for the detached scripts until the deadline nears, then copies their logs out."""
        pending = {p.stem for p in paths}
        while pending and self.left() > 150:
            time.sleep(15)
            r = target.run(" ".join(f"test -f {s}.done && echo {s};" for s in pending), timeout=30)
            for stem in r.stdout.decode().split():
                pending.discard(stem)
                log(f"   background {stem} finished after {int(time.time() - self.deployed_at)} s of VM time")
        for p in paths:
            r = target.run(f"cat -- {p.stem}.log; echo; echo '--- exit code ---'; cat {p.stem}.done 2>/dev/null || echo 'still running when the VM was stopped'",
                           timeout=min(60, max(10, self.left())))
            (self.dir / f"{p.stem}.log").write_bytes(r.stdout)
            log(f"   {p.stem}: {'finished' if p.stem not in pending else 'NOT FINISHED, partial log kept'}")

    def inside(self, target: Target, challenge: str) -> None:
        """nvidia-smi, pre-scripts, the published two-proofs script, the bundle copied out, extra scripts."""
        for s in self.args.pre_script:
            self.run_script(target, pathlib.Path(s), {}, min(120, self.left()))
        r = target.run("nvidia-smi; echo; nvidia-smi conf-compute -q; echo; uname -r; ls -l /dev/tdx_guest; systemd-detect-virt",
                       timeout=min(60, self.left()))
        (self.dir / "nvidia-smi.txt").write_bytes(r.stdout + r.stderr)
        log(f"   nvidia-smi exit {r.returncode}: {r.stdout.decode(errors='replace').splitlines()[0] if r.stdout else ''}")
        with urllib.request.urlopen(VM_SCRIPT_URL, timeout=60) as resp:
            script = resp.read().decode().replace("\r\n", "\n")
        (self.dir / "two-proofs-in-the-vm.sh").write_text(script, newline="\n")
        log(f"   running {VM_SCRIPT_URL.rsplit('/', 1)[1]} with CHALLENGE drawn here")
        r = target.run(f"CHALLENGE={challenge} bash -s", stdin=script, timeout=min(600, self.left()))
        (self.dir / "in-the-vm.txt").write_bytes(r.stdout)
        (self.dir / "in-the-vm.stderr.txt").write_bytes(r.stderr)
        log(f"   two-proofs exit {r.returncode}, last line: {r.stdout.decode(errors='replace').strip().splitlines()[-1:]}")
        self.copy_out(target, ["manifest.json", "bundle.json", "SHA256SUMS"])
        log(f"   bundle copied out after {int(time.time() - self.deployed_at)} s")
        background = [pathlib.Path(s) for s in self.args.background_script]
        for p in background:
            self.start_background(target, p)
        for spec in self.args.script:
            path, cap = split_cap(spec)
            if self.left() < 300:
                log(f"   {path.name}: NOT EXECUTED, {int(self.left())} s left before the deadline")
                continue
            # At most its own cap, and always four minutes kept to collect logs and stop the VM.
            budget = min(cap, self.left() - 240)
            self.run_script(target, path, {"BUDGET_SECONDS": str(int(budget))}, budget)
        if background:
            self.collect_background(target, background)

    def verify_offline(self, challenge: str) -> None:
        sums = {l.split()[1]: l.split()[0] for l in (self.dir / "SHA256SUMS").read_text().splitlines() if l.strip()}
        import hashlib
        for name in ("manifest.json", "bundle.json"):
            if hashlib.sha256((self.dir / name).read_bytes()).hexdigest() != sums.get(name):
                raise SystemExit(f"checksum mismatch for {name}")
        if json.loads((self.dir / "manifest.json").read_text())["challenge"] != challenge:
            raise SystemExit("the manifest does not carry the challenge drawn here")
        base = [sys.executable, "-m", "voltage_verify", "verify", str(self.dir / "bundle.json"), "--offline",
                "--hwmodel", HWMODEL.get(self.args.sku, "GB20X"), "--gpus", "1"]
        good = subprocess.run([*base, "--challenge", challenge], capture_output=True, text=True)
        # LF on every platform: the evidence folder is compared byte for byte later.
        (self.dir / "verify.txt").write_text(good.stdout, newline="\n")
        bad = subprocess.run([*base, "--challenge", "0" * 64], capture_output=True, text=True)
        (self.dir / "verify-wrong-challenge.txt").write_text(bad.stdout, newline="\n")
        result = [l for l in good.stdout.splitlines() if l.startswith("RESULT")]
        log(f"offline verify: exit {good.returncode}, {result}; wrong challenge: "
            f"{[l for l in bad.stdout.splitlines() if l.startswith('RESULT')]}")

    def main(self) -> int:
        challenge = secrets.token_hex(32)
        log(f"SSH key: {ensure_ssh_key(self.api, self.args.ssh_key)}")
        self.deploy()
        watchdog = threading.Timer(self.soft_s, lambda: (log("WATCHDOG: soft deadline, stopping the VM"), self.stop_once()))
        watchdog.daemon = True
        watchdog.start()
        signal.signal(signal.SIGINT, lambda *_: (log("interrupted: stopping the VM"), self.stop_once(), sys.exit(1)))
        try:
            target = self.wait_address()
            if not wait_ssh(target, time.time() + self.left() - 4 * 60):
                raise RuntimeError("sshd never answered")
            log(f"   ssh up after {int(time.time() - self.deployed_at)} s ({target.host}:{target.port})")
            self.inside(target, challenge)
        finally:
            watchdog.cancel()
            stopped = self.stop_once()
            vm_s = int(stopped["at"] - self.deployed_at)
            if not stopped["ok"]:
                log(f"STOP FAILED after {vm_s} s: the VM may STILL be running. Run --reap, or stop it at {SITE}/dashboard; "
                    "the hardstop_hours=1 asked at deploy stops it within the hour in any case.")
            else:
                log(f"VM stop via {stopped['via']} after {vm_s} s of VM time; confirming through GET /api/volt/pods")
            gone = self.confirm_gone()
            log(f"   {'no longer listed' if gone else 'STILL LISTED: check ' + SITE + '/dashboard'}")
            time.sleep(3)
            st, bal = self.api.call("GET", "/api/volt/balance")
            after = bal.get("balance") if st == 200 else None
            cost = None if after is None else round(self.facts["balance_before"] - after, 4)
            log(f"billing: balance {self.facts['balance_before']:.4f} -> {after} $, net cost {cost} $ "
                f"for {vm_s} s at {self.facts['price']} $/h (one hour prepaid at deploy, unused seconds refunded)")
            self.save(vmSeconds=vm_s, balanceAfter=after, netCost=cost, gone=gone, challenge=challenge)
        self.verify_offline(challenge)
        return 0


def split_cap(spec: str) -> tuple[pathlib.Path, float]:
    """'a.sh:600' -> (a.sh, 600 s); 'a.sh' -> (a.sh, no cap). A Windows drive colon is not a cap."""
    head, sep, tail = spec.rpartition(":")
    if sep and tail.isdigit() and head:
        return pathlib.Path(head), float(tail)
    return pathlib.Path(spec), float("inf")


def reap(api: Api) -> int:
    for state in sorted(RUNS.glob("*/state.json")):
        s = json.loads(state.read_text())
        if s.get("podId") and not s.get("stopped"):
            log(f"{state.parent.name}: pod {s['podId']} recorded as active, stopping")
            st, _ = api.call("POST", f"/api/volt/pods/{s['podId']}/stop")
            log(f"   POST /stop -> HTTP {st}")
            s["stopped"] = {"via": "reap", "at": time.time(), "status": st}
            state.write_text(json.dumps(s, indent=2))
    st, pods = api.call("GET", "/api/volt/pods")
    log(f"confidential VMs running now: {sum(1 for p in (pods if isinstance(pods, list) else []) if p.get('provider') == 'confidential')}")
    return 0


def parse() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="guards only, nothing rented")
    mode.add_argument("--run", action="store_true", help="deploy, attest, stop, verify")
    mode.add_argument("--reap", action="store_true", help="stop a VM a killed run left behind")
    p.add_argument("--sku", default="rtx6000b-small")
    p.add_argument("--ssh-key", help="private key; <key>.pub is registered on the account if needed")
    p.add_argument("--max-minutes", type=int, default=30, help="hard cap on VM lifetime (watchdog at cap - 5)")
    p.add_argument("--pre-script", action="append", default=[], help="bash script run in the VM before the attestation")
    p.add_argument("--script", action="append", default=[],
                   help="bash script run in the VM after the bundle is copied out, in order; path:seconds caps its time")
    p.add_argument("--background-script", action="append", default=[],
                   help="bash script started detached in the VM after the bundle is copied out; its log is collected at the end")
    a = p.parse_args()
    if a.run and not a.ssh_key:
        p.error("--run needs --ssh-key")
    if a.max_minutes < 10 or a.max_minutes > 60:
        p.error("--max-minutes between 10 and 60")
    return a


if __name__ == "__main__":
    key = os.environ.get("VOLTAGEGPU_VOLT_API_KEY")
    if not key or not key.startswith("volt_"):
        raise SystemExit("set VOLTAGEGPU_VOLT_API_KEY to a GPU Pods key (volt_...)")
    args = parse()
    api = Api(key)
    if args.reap:
        sys.exit(reap(api))
    facts = guards(api, args.sku)
    if args.check:
        log("check only: nothing rented")
        sys.exit(0)
    sys.exit(Run(api, args, facts).main())
