# Verify a published attestation bundle, offline (Jupyter notebook)

[`verify-attestation.ipynb`](verify-attestation.ipynb) downloads the evidence bundle VoltageGPU
published for its 9 October 2026 proof run (one RTX PRO 6000 Blackwell GPU in an Intel TDX guest,
SKU `rtx6000b-small`), checks the checksums, verifies it **offline** with
[voltage-verify](https://github.com/VoltageGPU/voltage-verify) 0.2.3, explains every line of the
verifier's output with the wording of the tool's own `docs/WHAT_IT_PROVES.md`, breaks the bundle on
purpose twice (wrong challenge, one byte changed in the quote), prints the machine-readable facts
(`MRTD`, `RTMR0..3`, TD attributes, TCB status, GPU claims) and ends with what the result does not
prove, unchanged from the tool's documentation.

No account, no GPU rental: the bundle is public,
<https://voltagegpu.com/blog/two-proofs/evidence/rtx6000b-2026-10-09/>.

## Run

```bash
pip install "voltage-verify==0.2.3" jupyter
jupyter notebook verify-attestation.ipynb        # run all cells
```

`build_notebook.py` is the source of the notebook (it writes the cells); the committed `.ipynb` was
produced by it and then executed with `jupyter nbconvert --to notebook --execute --inplace`, so the
outputs it contains are real, not typed.

## Executed on 2026-10-23

Environment: Windows 11, Python 3.12.4, voltage-verify 0.2.3, nbconvert 7.17.2, nbformat 5.11.1.
Result lines of the three verifications in the notebook:

```text
$ python -m voltage_verify verify downloads/bundle.json --offline --challenge 627ba9c5... --hwmodel GB20X --gpus 1
[PASS] manifest.format       manifest is well formed
[PASS] manifest.commitments  bundle commitments match the manifest
[PASS] manifest.challenge    challenge is the one this verifier issued
[PASS] tdx.structure         TDX quote v4, TEE 0x81, 4940 bytes
[PASS] tdx.debug             TD attributes 0000001000000000 (0x10000000), DEBUG (bit 0) off: not a debug TD
[PASS] tdx.report_data       quote report_data equals SHA-512 of the manifest
[PASS] tdx.signatures        attestation key, QE binding, QE report and PCK chain verify up to the pinned Intel SGX Root CA
[PASS] tdx.collateral        TCB info and QE identity signed by Intel (bundle (fetched 2026-10-09T21:54:01+00:00))
[PASS] tdx.tcb               platform TCB UpToDate, QE UpToDate, TDX_03 UpToDate
[PASS] tdx.revocation        PCK certificate not revoked (57 entries in CRL)
[PASS] tdx.revocation        PCK CA certificate not revoked (0 entries in CRL)
[PASS] nvidia.signatures     2 NVIDIA-signed tokens verify, keys from the bundle chained to a pinned NRAS intermediate (offline)
[PASS] nvidia.nonce          NRAS eat_nonce equals SHA-256 of the manifest
[PASS] nvidia.policy         overall result true, every GPU: measurements ok, secure boot on, debug off, nonce matched, report signature and chain validated
[PASS] nvidia.freshness      token issued 0s from bundle creation

TDX: MRTD eea8b6a814569a52bd1e12f6b869bb2d...  TCB UpToDate  QE UpToDate
GPU: GPU-0 GB20X driver 595.71.05 vbios 98.02.9E.00.01 measurements success

RESULT: VERIFIED
exit code: 0

$ ... --challenge 0000000000000000000000000000000000000000000000000000000000000000 ...
[FAIL] manifest.challenge    challenge differs from the one this verifier issued (replay or foreign bundle)
RESULT: NOT VERIFIED (manifest.challenge)
exit code: 1

$ ... downloads/tampered.json --offline --challenge 627ba9c5... ...
[FAIL] tdx.signatures        quote signature does not verify with the attestation key:
RESULT: NOT VERIFIED (tdx.signatures)
exit code: 1
```

The full output of every cell is in the notebook itself.

## What this does not show

The challenge of this bundle was drawn by the publisher's script, so the notebook does not
demonstrate freshness relative to *you*. For that, rent a Confidential VM, draw the challenge on your
own machine and attest inside the VM: `../deploy-confidential-vm-api` does exactly this.
