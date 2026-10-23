# Deploy a Confidential VM through the public API, attest it, stop it

`deploy_and_attest.py` does, from your machine, what a careful customer would do by hand:

1. **Guards** before spending: `GET /api/volt/balance` (one prepaid hour must be covered),
   `GET /api/volt/pods` (no confidential VM already running: never a second one),
   `GET /api/confidential/vm/tiers` (the tier is listed, `available > 0`, `attestation.verified`),
   a local `voltage-verify >= 0.2.3`, an SSH client.
2. `POST /api/volt/pods` with `{"provider": "confidential", "name": ..., "resource_name": "rtx6000b-small",
   "hardstop_hours": 1}`. The answer carries the pod id, the hourly price read server-side, the site's
   own hard stop time, and a one-time sudo password that the script never logs.
3. Polls `GET /api/volt/pods` until `ssh_ready` is true, then waits for sshd.
4. Inside the VM: `nvidia-smi`, `nvidia-smi conf-compute -q`, kernel and `/dev/tdx_guest`; then the
   published script <https://voltagegpu.com/blog/two-proofs/evidence/two-proofs-in-the-vm.sh> with a
   64-hex **challenge drawn on your machine**, so an old bundle cannot be replayed; the bundle,
   manifest and checksums are copied out over SSH.
5. Optional extra scripts (`--pre-script`, `--script path[:seconds]` run in order with a time cap,
   `--background-script` started detached and collected at the end; `--no-attest` skips step 4's
   attestation, `--soft-minutes` and `--reserve-seconds` tune the deadlines for short runs): this is how
   `../vllm-in-tee`, `../dstack-ssh-fleet` and `../skypilot` ran on the same VM.
6. **`finally`**: `POST /api/volt/pods/{id}/stop` (retried, `DELETE` as fallback), confirmed by the
   VM disappearing from `GET /api/volt/pods`; a watchdog does the same at `--max-minutes - 5`; every
   wait ends before that deadline; `hardstop_hours: 1` is the site's own net under all of this.
7. Billing read back through `GET /api/volt/balance`, then the bundle is verified **offline, here**,
   with the challenge, and once more with a wrong challenge to show the failure.

Standard library only. Keys: a **GPU Pods** key (`volt_...`, <https://voltagegpu.com/api-keys>) in
`VOLTAGEGPU_VOLT_API_KEY`; an SSH key pair, whose public half the script registers through
`POST /api/volt/ssh-keys` if the account does not have it yet.

```bash
pip install "voltage-verify>=0.2.3"
export VOLTAGEGPU_VOLT_API_KEY=volt_...
python deploy_and_attest.py --check                              # guards only, nothing rented
python deploy_and_attest.py --run --ssh-key ~/.ssh/id_ed25519    # about 4 minutes and 0.25 $ alone
python deploy_and_attest.py --reap                               # if a run was killed: stop what it left
```

Billing on this tier: one hour (3.80 $ on 2026-10-23) is charged when the deploy succeeds, the unused
seconds are refunded when the VM is released. Releasing after 4 minutes costs about 0.25 $.

## Executed on 2026-10-23

Windows 11, Python 3.12.4, voltage-verify 0.2.3, OpenSSH for Windows. One VM, SKU `rtx6000b-small`
(one NVIDIA RTX PRO 6000 Blackwell Server Edition, 32 vCPU, 121 GB RAM, 277 GB of disk available, Ubuntu
24.04.4 LTS). The three extra scripts of the other examples ran on it, which is why the VM lived
19 minutes instead of 4. Unedited orchestrator output
([`output-2026-10-23.txt`](output-2026-10-23.txt), local times UTC+2, public IP masked):

```text
13:53:55 balance 10.61 $, rtx6000b-small 3.8 $/h, 8 available, attestation verified 2026-10-09, voltage-verify 0.2.3, 0 confidential VM running
13:53:55 SSH key: already registered
13:53:55 POST /api/volt/pods {"provider": "confidential", "name": "cookbook-20261023", "resource_name": "rtx6000b-small", "hardstop_hours": 1}
13:54:10    HTTP 200: pod cmvkwwhzj000el2086wy3trr2, workload wrk-0x2ixdmlci9w, 3.8 $/h, site hard stop at 2026-10-23T12:54:10.214Z, sudo password: returned once, not logged
13:54:25    30 s  provider_status provisioning  ssh_ready False
...
13:56:30    155 s  provider_status running  ssh_ready True
13:56:33    ssh up after 158 s (<vm public ip>:20007)
13:56:33    >> in-vm-prepare.sh (budget 120 s)
13:56:35    << in-vm-prepare.sh exit 0, 4 lines, last: [11:56:34] background jobs started: vllm-install, host-install, tools-install (logs: *-install.log)
13:56:37    nvidia-smi exit 0: Fri Oct 23 11:56:35 2026
13:56:37    running two-proofs-in-the-vm.sh with CHALLENGE drawn here
13:57:12    two-proofs exit 0, last line: ['== archive ready: /tmp/proofs.tgz']
13:57:17    bundle copied out after 202 s
13:57:20    background: in-vm-dstack.sh started (budget 1056 s)
13:57:23    background: in-vm-skypilot.sh started (budget 1053 s)
13:57:23    >> in-vm-vllm.sh (budget 961 s)
14:12:27    << in-vm-vllm.sh exit 2, 41 lines, last: RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}
14:12:43    background in-vm-dstack finished after 1128 s of VM time
14:12:43    background in-vm-skypilot finished after 1128 s of VM time
14:12:45    in-vm-dstack: finished
14:12:46    in-vm-skypilot: finished
14:12:49    POST /api/volt/pods/{id}/stop -> HTTP 200
14:12:49 VM stop via stop after 1134 s of VM time; confirming through GET /api/volt/pods
14:12:50    no longer listed
14:12:53 billing: balance 10.6114 -> 9.4309 $, net cost 1.1805 $ for 1134 s at 3.8 $/h (one hour prepaid at deploy, unused seconds refunded)
14:12:54 offline verify: exit 0, ['RESULT: VERIFIED']; wrong challenge: ['RESULT: NOT VERIFIED (manifest.challenge)']
```

The stop answer was `{"success": true, "finalCharge": 0, "prepaidRefund": 2.62}`: 3.80 $ charged at
deploy, 2.62 $ returned, **1.18 $ net for 18 min 54 s**.

### What the VM reported (`evidence-2026-10-23/nvidia-smi.txt`)

```text
NVIDIA-SMI 595.71.05   Driver Version: 595.71.05   CUDA Version: 13.2
GPU 0  NVIDIA RTX PRO 6000 Blackwell Server Edition   0MiB / 97887MiB
    CC State                   : ON
    Multi-GPU Mode             : None
    CPU CC Capabilities        : INTEL TDX
    GPU CC Capabilities        : CC Capable
    CC GPUs Ready State        : Ready
6.8.0-110-generic
crw------- 1 root root 10, 262 Oct 23 11:56 /dev/tdx_guest
kvm
```

### The two proofs, verified offline on this machine (`evidence-2026-10-23/verify.txt`)

```text
$ python -m voltage_verify verify bundle.json --offline --challenge bee86ef2... --hwmodel GB20X --gpus 1
[PASS] manifest.format       manifest is well formed
[PASS] manifest.commitments  bundle commitments match the manifest
[PASS] manifest.challenge    challenge is the one this verifier issued
[PASS] tdx.structure         TDX quote v4, TEE 0x81, 4940 bytes
[PASS] tdx.debug             TD attributes 0000001000000000 (0x10000000), DEBUG (bit 0) off: not a debug TD
[PASS] tdx.report_data       quote report_data equals SHA-512 of the manifest
[PASS] tdx.signatures        attestation key, QE binding, QE report and PCK chain verify up to the pinned Intel SGX Root CA
[PASS] tdx.collateral        TCB info and QE identity signed by Intel (bundle (fetched 2026-10-23T11:57:11+00:00))
[PASS] tdx.tcb               platform TCB UpToDate, QE UpToDate, TDX_03 UpToDate
[PASS] tdx.revocation        PCK certificate not revoked (57 entries in CRL)
[PASS] tdx.revocation        PCK CA certificate not revoked (0 entries in CRL)
[PASS] nvidia.signatures     2 NVIDIA-signed tokens verify, keys from the bundle chained to a pinned NRAS intermediate (offline)
[PASS] nvidia.nonce          NRAS eat_nonce equals SHA-256 of the manifest
[PASS] nvidia.policy         overall result true, every GPU: measurements ok, secure boot on, debug off, nonce matched, report signature and chain validated
[PASS] nvidia.freshness      token issued 2s from bundle creation

TDX: MRTD eea8b6a814569a52bd1e12f6b869bb2d...  TCB UpToDate  QE UpToDate
GPU: GPU-0 GB20X driver 595.71.05 vbios 98.02.9E.00.01 measurements success

RESULT: VERIFIED
```

With `--challenge 000...0`: `[FAIL] manifest.challenge ... RESULT: NOT VERIFIED (manifest.challenge)`
(`evidence-2026-10-23/verify-wrong-challenge.txt`). The folder `evidence-2026-10-23/` holds the
bundle (549 646 bytes), the manifest with the challenge `bee86ef2...`, `SHA256SUMS` computed in the
VM, what the published script printed inside the VM (`in-the-vm.txt`) and the prepare log. Anyone can
replay the verification:

```bash
cd evidence-2026-10-23 && sha256sum -c SHA256SUMS
voltage-verify verify bundle.json --offline --hwmodel GB20X --gpus 1 \
  --challenge "$(python3 -c "import json; print(json.load(open('manifest.json'))['challenge'])")"
```

What this proves and does not prove is spelled out in `../verify-attestation-notebook` (section 7) with
the words of voltage-verify's `WHAT_IT_PROVES.md`.

### Second run, same day (13:23 to 13:31 UTC)

Same script with the three other examples run in order with time caps
(`--max-minutes 40 --script ../vllm-in-tee/in-vm-vllm.sh:720 --script ../dstack-ssh-fleet/in-vm-dstack.sh:480
--script ../skypilot/in-vm-skypilot.sh:900`). The VM was stopped as soon as the last script returned.
Unedited output in [`output-2026-10-23-run2.txt`](output-2026-10-23-run2.txt):

```text
15:23:24 POST /api/volt/pods {"provider": "confidential", "name": "cookbook-20261023", "resource_name": "rtx6000b-small", "hardstop_hours": 1}
15:23:39    HTTP 200: pod cmvl03l8o000dl608wvtv4if5, workload wrk-0wf8t4mta311, 3.8 $/h, site hard stop at 2026-10-23T14:23:39.873Z, sudo password: returned once, not logged
15:26:03    ssh up after 158 s (<vm public ip>:<port>)
15:26:43    two-proofs exit 0, last line: ['== archive ready: /tmp/proofs.tgz']
15:26:48    >> in-vm-vllm.sh (budget 720 s)
15:31:14    << in-vm-vllm.sh exit 0, 64 lines, last: [13:31:14] == vLLM stopped after 264 s
15:31:24    << in-vm-dstack.sh exit 1, 13 lines, last: [13:31:24] ssh ubuntu@127.0.0.1 with the new key: FAILED. NOT EXECUTED: fleet and task (dstack canno
15:31:31    << in-vm-skypilot.sh exit 1, 5 lines, last: [13:31:31] ssh ubuntu@127.0.0.1 with the new key: FAILED. NOT EXECUTED: sky ssh up and sky launch
15:31:33    POST /api/volt/pods/{id}/stop -> HTTP 200
15:31:34    no longer listed
15:31:37 billing: balance 9.4309 -> 8.9309 $, net cost 0.5 $ for 489 s at 3.8 $/h (one hour prepaid at deploy, unused seconds refunded)
15:31:37 offline verify: exit 0, ['RESULT: VERIFIED']; wrong challenge: ['RESULT: NOT VERIFIED (manifest.challenge)']
```

Ledger of the account: 3.80 $ charged at deploy, 3.30 $ refunded at release, **0.50 $ net**. The
bundle of this second run verified the same way (fresh challenge, `RESULT: VERIFIED`); it is not added
to the repository, the first one already shows it.

### Third run, same day (13:44 to 13:53 UTC)

`--no-attest --max-minutes 16 --soft-minutes 14 --reserve-seconds 45`, with `in-vm-selfssh.sh` as a
second pre-script and the three other examples as background scripts. Unedited output in
[`output-2026-10-23-run3.txt`](output-2026-10-23-run3.txt): SSH after 162 s, the VM stopped at 516 s
(`POST /stop` 200, no longer listed), ledger 3.80 $ charged and 3.27 $ refunded, **0.53 $ net**. What
the scripts did is in `../vllm-in-tee`, `../dstack-ssh-fleet` and `../skypilot`.

### Observed on this image, useful before you script against it

* `pip` is not on the image; the published script installs it with `get-pip.py` (and `uv` installs
  in two seconds, see `in-vm-prepare.sh`).
* `~/.ssh` belongs to root on this image (`drwxr-xr-x root root /home/ubuntu/.ssh`, seen on the second
  and third runs), while `authorized_keys` belongs to `ubuntu` (mode 600). So `ssh-keygen -f ~/.ssh/<name>`
  as `ubuntu` fails with `Permission denied`, and so does anything that writes `~/.ssh/known_hosts` or
  `~/.ssh/config`. `sudo chown ubuntu:ubuntu ~/.ssh && chmod 700 ~/.ssh` fixes it.
* `authorized_keys` ends without a final newline (seen on the third run: its last byte is the end of a
  key comment). A key added with `cat key.pub >> ~/.ssh/authorized_keys` is glued to the last line and
  is not accepted; add a newline first. With that, a second key worked at once
  (`in-vm-selfssh.sh`).
* Without gcc and the Python headers (absent from the image), Triton cannot build its launcher; install
  `build-essential python3-dev` before anything that runs Triton kernels (vLLM does).
* Passwordless `sudo` works for `ubuntu`; outbound HTTPS, PyPI, Docker Hub and apt mirrors were
  reachable; `curl https://get.docker.com | sh` plus the NVIDIA Container Toolkit took about 75 s.
