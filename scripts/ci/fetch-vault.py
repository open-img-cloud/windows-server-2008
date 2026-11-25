#!/usr/bin/env python3
"""Fetches files pinned in a sha256 list from the open-img-cloud ISO vault.

Usage: fetch-vault.py <list.sha256> <output dir>

Each line of the list is "<sha256>  <key in the vault>"; the file lands in
<output dir>/<basename of the key>. The vault is a private bucket of another
Infomaniak project, read with a read-only key (OIC_ISO_VAULT_KEY_ID /
OIC_ISO_VAULT_SECRET) and addressed as "<project>:<bucket>" (Ceph tenants).
A file that does not match its pinned sha256 is deleted and the run fails.
"""
import hashlib
import os
import sys

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.handlers import validate_bucket_name

ENDPOINT = "https://s3.gva2.infomaniak.cloud"
BUCKET = "c0862b7f7b6849508bbcd74fb00e7fe2:oic-iso-vault"

listing, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
s3 = boto3.client(
    "s3",
    endpoint_url=ENDPOINT,
    region_name="us-east-1",
    aws_access_key_id=os.environ["OIC_ISO_VAULT_KEY_ID"],
    aws_secret_access_key=os.environ["OIC_ISO_VAULT_SECRET"],
)
# boto3 rejects the colon of a tenant-qualified bucket name.
s3.meta.events.unregister("before-parameter-build.s3", validate_bucket_name)
config = TransferConfig(multipart_chunksize=64 << 20, max_concurrency=8)

for line in open(listing):
    if not line.strip():
        continue
    expected, key = line.split()
    out = os.path.join(outdir, os.path.basename(key))
    s3.download_file(BUCKET, key, out, Config=config)
    h = hashlib.sha256()
    with open(out, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != expected:
        os.remove(out)
        sys.exit(f"sha256 mismatch for {key}: got {h.hexdigest()}, pinned {expected}")
    print(f"ok {key} ({os.path.getsize(out)} bytes)")
