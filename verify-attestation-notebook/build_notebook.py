"""Writes verify-attestation.ipynb. Run it, then execute the notebook with nbconvert so every
output cell is real:

    python build_notebook.py
    jupyter nbconvert --to notebook --execute --inplace verify-attestation.ipynb
"""
import nbformat as nbf

nb = nbf.v4.new_notebook()
nb.metadata["kernelspec"] = {"name": "python3", "display_name": "Python 3", "language": "python"}
cells = []


def md(text: str) -> None:
    cells.append(nbf.v4.new_markdown_cell(text.strip("\n")))


def code(text: str) -> None:
    cells.append(nbf.v4.new_code_cell(text.strip("\n")))


md("""
# Verify a published VoltageGPU attestation bundle, offline

This notebook downloads an evidence bundle that VoltageGPU publishes on its website, checks its
checksums, and verifies it **on this machine, without network access during verification**, with
[`voltage-verify`](https://github.com/VoltageGPU/voltage-verify) 0.2.3. Then it explains each line of
the verifier's output, breaks the bundle on purpose to show the checks fail, and ends with what the
result does **not** prove.

The bundle was captured on 9 October 2026 inside a VoltageGPU Confidential VM (SKU `rtx6000b-small`:
one NVIDIA RTX PRO 6000 Blackwell GPU in an Intel TDX guest), rented through the public API by the
weekly proof run. Its folder also holds the output printed inside the VM and the `nvidia-smi` and
kernel details: <https://voltagegpu.com/blog/two-proofs/evidence/rtx6000b-2026-10-09/README.txt>.

No account is needed. Requirements: Python 3.10+, `pip install "voltage-verify==0.2.3"`.
""")

code("""
import hashlib, json, pathlib, subprocess, sys, urllib.request

EVIDENCE = "https://voltagegpu.com/blog/two-proofs/evidence/rtx6000b-2026-10-09"
FILES = ["bundle.json", "manifest.json", "SHA256SUMS"]
dl = pathlib.Path("downloads"); dl.mkdir(exist_ok=True)

for name in FILES:
    with urllib.request.urlopen(f"{EVIDENCE}/{name}", timeout=60) as r:
        (dl / name).write_bytes(r.read())
    print(f"{name:14} {(dl / name).stat().st_size:>8} bytes")
""")

md("""
## 1. Checksums

`SHA256SUMS` was computed inside the VM, right after the bundle was written. Recomputing the hashes
here shows the files were served byte for byte. (It does not prove anything about their content yet:
anyone can publish a file and its hash. The signatures checked below do that.)
""")

code("""
published = {line.split()[1]: line.split()[0]
             for line in (dl / "SHA256SUMS").read_text().splitlines() if line.strip()}
for name in ("manifest.json", "bundle.json"):
    digest = hashlib.sha256((dl / name).read_bytes()).hexdigest()
    print(f"{name:14} {'OK' if digest == published[name] else 'MISMATCH'}  {digest}")
""")

md("""
## 2. The manifest and its challenge

The manifest is the small JSON document both hardware proofs are bound to. It carries a random
`challenge`; for a bundle you produce yourself you draw it on your own machine and pass it to the
VM, so an old bundle cannot be replayed to you. Here the challenge was drawn by the publisher's
script, so we read it from the manifest and pass it to the verifier with `--challenge`.
""")

code("""
manifest = json.loads((dl / "manifest.json").read_text())
print(json.dumps(manifest, indent=2))
CHALLENGE = manifest["challenge"]
""")

md("""
## 3. Verify, offline

`voltage-verify verify` runs every check and prints one line per check. Options used:

* `--offline`: read the Intel collateral (TCB info, QE identity, CRLs) embedded in the bundle, itself
  checked against the pinned Intel SGX Root CA, instead of fetching it from Intel. NVIDIA's signing
  keys always come from the bundle's JWKS, trusted only through their certificate chain to a pinned
  NVIDIA NRAS intermediate.
* `--challenge`: the challenge the bundle must answer.
* `--hwmodel GB20X --gpus 1`: the GPU model and count NVIDIA's token must report (RTX PRO 6000
  Blackwell is `GB20X`).

Exit code 0 means verified, 1 means a required check failed, 2 means the bundle or arguments are
unusable.
""")

code("""
def verify(*args):
    cmd = [sys.executable, "-m", "voltage_verify", "verify", *args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    shown = [CHALLENGE[:8] + "..." if a == CHALLENGE else a for a in cmd[2:]]
    print("$ python -m", " ".join(shown))
    print(r.stdout + r.stderr)
    print("exit code:", r.returncode)
    return r

print(subprocess.run([sys.executable, "-m", "voltage_verify", "--version"],
                     capture_output=True, text=True).stdout)
ok = verify(str(dl / "bundle.json"), "--offline", "--challenge", CHALLENGE, "--hwmodel", "GB20X", "--gpus", "1")
assert ok.returncode == 0 and "RESULT: VERIFIED" in ok.stdout
""")

md("""
## 4. What each line means

The reading below is the one from the tool's own documentation,
[`docs/WHAT_IT_PROVES.md`](https://github.com/VoltageGPU/voltage-verify/blob/main/docs/WHAT_IT_PROVES.md),
reproduced for the checks printed above and nothing more.

### Manifest

| Check | Passes when | Proves | Does not prove |
|---|---|---|---|
| `manifest.format` | the manifest has the expected shape | the bundle is parseable | anything |
| `manifest.commitments` | SHA-256 and SHA-512 of the canonical manifest equal the stored values | bookkeeping is consistent | anything: an attacker can recompute them |
| `manifest.challenge` | the challenge equals the one you passed with `--challenge` | the bundle was made for this session | anything without the TDX and NVIDIA checks below |

### Intel TDX

| Check | Passes when | Proves | Does not prove |
|---|---|---|---|
| `tdx.structure` | version 4 quote, TEE type TDX, ECDSA-P256 key, QE report and PCK chain present | it is a TDX quote | anything about its origin |
| `tdx.debug` | bit 0 (DEBUG) of the TD attributes is 0; with `--allow-debug` a set bit is a warning, not a failure | the TD does not run in debug mode, in which the host can read and modify its memory and CPU state | anything on its own: the TD attributes are only Intel's word once `tdx.signatures` passes |
| `tdx.report_data` | the quote's 64-byte `report_data` equals `SHA-512(manifest)` | the quote was requested with your manifest hash, so after your challenge | who requested it |
| `tdx.signatures` | attestation key signs header+report; QE report binds the key; PCK certificate signs the QE report; PCK chain verifies to the pinned Intel SGX Root CA and is within validity | the quote was produced by a genuine Intel TDX Quoting Enclave on Intel-provisioned hardware | that the platform's firmware is current |
| `tdx.collateral` | TCB info and QE identity carry Intel's signature and chain to the root | the collateral is Intel's | freshness (see `tdx.collateral_fresh`) |
| `tdx.tcb` | the platform's SVNs (from the PCK certificate and the quote's `tee_tcb_svn`) reach a level Intel rates `UpToDate` or `SWHardeningNeeded`; the TDX module identity matches; the Quoting Enclave identity matches and is `UpToDate` | the platform is patched to a level Intel accepts | that no unknown vulnerability exists |
| `tdx.revocation` | the PCK certificate and its CA are absent from Intel's CRLs | Intel has not revoked this platform's provisioning identity | anything if CRLs are missing (then the line says NOT checked) |

The quote's `MRTD` and `RTMR0..3` are printed as facts. They measure the VM's initial state
and boot chain. This tool does not compare them to a reference: whether a given `MRTD` is the
image you expect is a policy decision that belongs to you.

### NVIDIA

| Check | Passes when | Proves | Does not prove |
|---|---|---|---|
| `nvidia.signatures` | the verifier token and every device token verify (ES384/ES256 on the matching curve) with a key from the bundle's JWKS, listed once, whose x5c leaf names NVIDIA Corporation, holds that key, is issued by a pinned NRAS intermediate, GPU Intermediate 004 or 005 (or one NVIDIA's live JWKS presents) and was valid at the token's `iat`; issuer is NRAS | NVIDIA issued these claims | when, until `nvidia.freshness` |
| `nvidia.nonce` | `eat_nonce` equals `SHA-256(manifest)` | the claims were issued for your manifest hash, after your challenge | which VM: the TDX side does that |
| `nvidia.policy` | overall result true; every GPU: `measres` success, `secboot` true, `dbgstat` disabled, nonce matched, report signature verified, certificate chain validated; optional `--hwmodel` and `--gpus` | NVIDIA's service accepted the GPU's measurements and configuration | that the GPU executed your workload |
| `nvidia.freshness` | the verifier token's `iat` is within 15 minutes of the bundle's `created_at` | the token belongs to this attestation session | anything if the VM clock is wrong (the check then fails, which is the safe direction) |

The two summary lines (`TDX: MRTD ...` and `GPU: GPU-0 GB20X driver ...`) are facts read from the
quote and from NVIDIA's token, printed for you to compare against your own policy.
""")

md("""
## 5. Break it on purpose

A replayed or foreign bundle answers a challenge you did not issue: `manifest.challenge` fails.
""")

code("""
bad = verify(str(dl / "bundle.json"), "--offline", "--challenge", "0" * 64, "--hwmodel", "GB20X", "--gpus", "1")
assert bad.returncode != 0 and "NOT VERIFIED" in bad.stdout
""")

md("""
One changed character inside the signed part of the Intel quote: the attestation key's signature no
longer verifies, so `tdx.signatures` fails, whatever the challenge.
""")

code("""
bundle = json.loads((dl / "bundle.json").read_text())
quote = bundle["tdx"]["quote_b64"]
bundle["tdx"]["quote_b64"] = quote[:300] + ("A" if quote[300] != "A" else "B") + quote[301:]
(dl / "tampered.json").write_text(json.dumps(bundle))
tampered = verify(str(dl / "tampered.json"), "--offline", "--challenge", CHALLENGE, "--hwmodel", "GB20X", "--gpus", "1")
assert tampered.returncode != 0 and "NOT VERIFIED" in tampered.stdout
""")

md("""
## 6. The machine-readable report

`--json` prints the same checks plus the facts the verifier read: TD attributes, `MRTD`, `RTMR0..3`,
TCB status, the GPU claims. These are the values a policy of yours would compare against a reference.
""")

code("""
r = subprocess.run([sys.executable, "-m", "voltage_verify", "verify", str(dl / "bundle.json"), "--offline",
                    "--challenge", CHALLENGE, "--hwmodel", "GB20X", "--gpus", "1", "--json"],
                   capture_output=True, text=True)
report = json.loads(r.stdout)
print("ok:", report["ok"], "| checks:", len(report["checks"]), "| facts:", sorted(report["facts"]))
tdx = report["facts"]["tdx"]
for key in ("mr_td", "mr_seam", "td_attributes", "xfam", "tee_tcb_svn", "fmspc", "tcb_status", "tcb_level_date", "qe_status"):
    print(f"tdx.{key:16} {tdx[key]}")
for i, rtmr in enumerate(tdx["rtmr"]):
    print(f"tdx.rtmr{i:<12} {rtmr}")
print("tdx.tdx_module     ", tdx["tdx_module"])
nvidia = report["facts"]["nvidia"]
print("nvidia.mode        ", nvidia["mode"], "| issued_at", nvidia["issued_at"], "| expires_at", nvidia["expires_at"])
for device in nvidia["devices"]:
    print("nvidia.device      ", json.dumps(device))
""")

md("""
## 7. What VERIFIED does not mean

From the tool's README and `docs/WHAT_IT_PROVES.md`, unchanged:

Verified does **not** mean:

* that the GPU *executed* the image or model named in the manifest. Binding a manifest to a
  quote proves the hardware signed your description of the workload; proving that this exact
  code ran needs a measured launcher (for instance the Confidential Containers project with
  a key broker), which is outside this tool;
* anything about the VM's own software stack beyond what the TDX measurements (`MRTD`,
  `RTMR0..3`) say. The tool prints them; comparing them against a reference image is your
  policy, not the tool's;
* anything about a VM you did not attest yourself.

### The gap this tool does not close

Both proofs are bound to a description of the workload. Neither proof says that the
described image or model was what the GPU computed on. Closing that gap requires a measured
launch: a component inside the VM that measures the container image and the model before
starting them and extends a TDX runtime measurement (`RTMR`) with the result, so that the
quote itself carries the measurement. The Confidential Containers project (Kata + Trustee)
and similar stacks do this. `voltage-verify` stops one step earlier on purpose, and says so.

### About this particular bundle

Its challenge was drawn by the publisher's script, not by you, so freshness relative to you is not
shown here. For your own guarantee, rent a Confidential VM, draw the challenge on your machine and
run the attestation yourself: see `deploy-confidential-vm-api/` in this repository and
[`docs/ATTEST_ON_VM.md`](https://github.com/VoltageGPU/voltage-verify/blob/main/docs/ATTEST_ON_VM.md).
""")

nb.cells = cells
nbf.write(nb, "verify-attestation.ipynb")
print("written verify-attestation.ipynb with", len(cells), "cells")
