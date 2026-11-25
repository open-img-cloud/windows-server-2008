#!/usr/bin/env python3
"""Stores a built image in the private ISO vault, under images/.

Usage: store-image.py <image.qcow2> <prefix>

Uploads the image and its .sha256 next to it as
images/<prefix>/<basename>. The build key may only ADD files under images/
(no delete, no access to the ISOs). The images are never published:
Windows evaluation media must not be redistributed.
"""
import os
import sys

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.handlers import validate_bucket_name

ENDPOINT = "https://s3.gva2.infomaniak.cloud"
BUCKET = "c0862b7f7b6849508bbcd74fb00e7fe2:oic-iso-vault"

image, prefix = sys.argv[1], sys.argv[2].strip("/")
s3 = boto3.client(
    "s3",
    endpoint_url=ENDPOINT,
    region_name="us-east-1",
    aws_access_key_id=os.environ["OIC_ISO_VAULT_KEY_ID"],
    aws_secret_access_key=os.environ["OIC_ISO_VAULT_SECRET"],
)
s3.meta.events.unregister("before-parameter-build.s3", validate_bucket_name)
config = TransferConfig(multipart_chunksize=64 << 20, max_concurrency=8)

for path in (image, image + ".sha256"):
    key = f"images/{prefix}/{os.path.basename(path)}"
    s3.upload_file(path, BUCKET, key, Config=config)
    print(f"stored {key} ({os.path.getsize(path)} bytes)")
