#!/usr/bin/env python3
"""
Test client for the APIM Speech BATCH synthesis (async, long-form text) demo API.

Unlike test_tts.py (real-time, single request/response), this client:
  1. Submits a job:  PUT  {APIM_GATEWAY_URL}/speech/batch/synthesize/{job-id}
  2. Polls status:   GET  {APIM_GATEWAY_URL}/speech/batch/synthesize/{job-id}
     until the job's "status" is "Succeeded" or "Failed".
  3. Downloads the result directly from the "outputs.result" SAS URL in the status
     JSON - this is a Microsoft-managed storage URL, NOT proxied back through APIM
     (see README.md for why). The result is a .zip containing the synthesized
     .wav file(s), a debug JSON, and a summary JSON; this client unzips it and
     saves the audio locally.
  4. Optionally deletes the job afterwards: DELETE {APIM_GATEWAY_URL}/speech/batch/synthesize/{job-id}

Usage:
    python client/test_batch_tts.py \
        --gateway-url https://apim-speech-demo01.azure-api.net \
        --subscription-key <APIM_SUBSCRIPTION_KEY> \
        --text "This is a long-form batch synthesis test." \
        --output batch_output.wav

Environment variables (used as defaults if flags are omitted):
    APIM_GATEWAY_URL
    APIM_SUBSCRIPTION_KEY
"""

import argparse
import io
import os
import sys
import time
import uuid
import zipfile

import requests

TERMINAL_STATUSES = {"Succeeded", "Failed"}
POLL_INTERVAL_SECONDS = 3.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Test the APIM Speech batch synthesis endpoints.")
    parser.add_argument(
        "--gateway-url",
        default=os.environ.get("APIM_GATEWAY_URL"),
        help="APIM gateway base URL, e.g. https://apim-speech-demo01.azure-api.net",
    )
    parser.add_argument(
        "--subscription-key",
        default=os.environ.get("APIM_SUBSCRIPTION_KEY"),
        help="APIM subscription key (Ocp-Apim-Subscription-Key).",
    )
    parser.add_argument(
        "--text",
        default="This is a test of the Azure Speech Batch synthesis API through Azure API Management.",
        help="Text to synthesize.",
    )
    parser.add_argument("--voice", default=None, help="Optional Speech voice short name, e.g. en-US-JennyNeural.")
    parser.add_argument("--language", default=None, help="Optional SSML language, e.g. en-US.")
    parser.add_argument(
        "--output-format",
        default=None,
        help="Optional Speech output format, e.g. riff-24khz-16bit-mono-pcm.",
    )
    parser.add_argument("--job-id", default=None, help="Optional job id. A unique one is generated if omitted.")
    parser.add_argument("--output", default="batch_output.wav", help="Local file path to save the audio result.")
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=300.0,
        help="Maximum time to wait for the job to reach a terminal status before giving up.",
    )
    parser.add_argument(
        "--keep-job",
        action="store_true",
        help="Do not delete the job from the Speech service after downloading the result.",
    )
    return parser.parse_args()


def fail(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def main() -> int:
    args = parse_args()

    if not args.gateway_url:
        print("ERROR: --gateway-url (or APIM_GATEWAY_URL) is required.", file=sys.stderr)
        return 2
    if not args.subscription_key:
        print("ERROR: --subscription-key (or APIM_SUBSCRIPTION_KEY) is required.", file=sys.stderr)
        return 2

    job_id = args.job_id or f"apim-speech-demo-{uuid.uuid4().hex[:12]}"
    base_url = f"{args.gateway_url.rstrip('/')}/speech/batch/synthesize/{job_id}"
    headers = {
        "Content-Type": "application/json",
        "Ocp-Apim-Subscription-Key": args.subscription_key,
    }

    payload = {"text": args.text}
    if args.voice:
        payload["voice"] = args.voice
    if args.language:
        payload["language"] = args.language
    if args.output_format:
        payload["outputFormat"] = args.output_format

    # Step 1: submit the job
    print(f"PUT {base_url}  (job-id: {job_id})")
    try:
        response = requests.put(base_url, json=payload, headers=headers, timeout=30.0)
    except requests.RequestException as exc:
        return fail(f"job creation request failed: {exc}")

    print(f"HTTP status code: {response.status_code}")
    print(f"Response Content-Type: {response.headers.get('Content-Type', '<none>')}")
    if response.status_code != 201:
        print("Request did not succeed. Response body:", file=sys.stderr)
        print(response.text, file=sys.stderr)
        return 1

    status_body = response.json()
    print(f"Job created. Initial status: {status_body.get('status')}")

    # Step 2: poll until terminal status
    deadline = time.monotonic() + args.timeout_seconds
    while status_body.get("status") not in TERMINAL_STATUSES:
        if time.monotonic() > deadline:
            return fail(
                f"job did not reach a terminal status within {args.timeout_seconds}s "
                f"(last status: {status_body.get('status')}). Check again later with GET {base_url}."
            )
        time.sleep(POLL_INTERVAL_SECONDS)
        try:
            response = requests.get(base_url, headers=headers, timeout=30.0)
        except requests.RequestException as exc:
            return fail(f"status polling request failed: {exc}")
        if response.status_code != 200:
            print("Status check did not succeed. Response body:", file=sys.stderr)
            print(response.text, file=sys.stderr)
            return 1
        status_body = response.json()
        print(f"  ... status: {status_body.get('status')}")

    if status_body.get("status") != "Succeeded":
        print("Job finished with a non-success status. Full status body:", file=sys.stderr)
        print(status_body, file=sys.stderr)
        return 1

    # Step 3: download the result directly from the Microsoft-managed SAS URL
    # (NOT via APIM - see README.md "Batch synthesis" section for why).
    result_url = status_body.get("outputs", {}).get("result")
    if not result_url:
        return fail(f"job succeeded but no outputs.result URL was present: {status_body}")

    print("Downloading result archive from Microsoft-managed storage (direct SAS URL, not via APIM)...")
    try:
        result_response = requests.get(result_url, timeout=60.0)
        result_response.raise_for_status()
    except requests.RequestException as exc:
        return fail(f"result download failed: {exc}")

    try:
        with zipfile.ZipFile(io.BytesIO(result_response.content)) as archive:
            wav_names = [name for name in archive.namelist() if name.lower().endswith(".wav")]
            if not wav_names:
                return fail(f"no .wav file found in result archive (contents: {archive.namelist()})")
            with archive.open(wav_names[0]) as wav_file, open(args.output, "wb") as out_file:
                out_file.write(wav_file.read())
    except (zipfile.BadZipFile, OSError) as exc:
        return fail(f"could not extract audio from result archive: {exc}")

    print(f"Saved audio to: {args.output}")

    # Step 4: clean up the job (and its Microsoft-managed storage) unless asked to keep it
    if not args.keep_job:
        print(f"DELETE {base_url}  (cleaning up job)")
        try:
            delete_response = requests.delete(base_url, headers=headers, timeout=30.0)
            print(f"Delete HTTP status code: {delete_response.status_code}")
        except requests.RequestException as exc:
            print(f"WARNING: cleanup delete failed (job may remain until its TTL expires): {exc}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
