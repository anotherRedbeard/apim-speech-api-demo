#!/usr/bin/env python3
"""
Test client for the APIM Speech text-to-speech demo API.

Sends JSON text to:   POST {APIM_GATEWAY_URL}/speech/synthesize
Saves the returned audio to a local file and prints the HTTP status code
and response Content-Type.

Usage:
    python client/test_tts.py \
        --gateway-url https://apim-speech-demo01.azure-api.net \
        --subscription-key <APIM_SUBSCRIPTION_KEY> \
        --text "Hello, this is a test of Azure Speech through Azure API Management." \
        --output out.wav

Environment variables (used as defaults if flags are omitted):
    APIM_GATEWAY_URL
    APIM_SUBSCRIPTION_KEY
"""

import argparse
import os
import sys

import requests


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Test the APIM Speech synthesize endpoint.")
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
        default="Hello, this is a test of Azure Speech through Azure API Management.",
        help="Text to synthesize.",
    )
    parser.add_argument("--voice", default=None, help="Optional Speech voice short name, e.g. en-US-JennyNeural.")
    parser.add_argument("--language", default=None, help="Optional SSML language, e.g. en-US.")
    parser.add_argument(
        "--output-format",
        default=None,
        help="Optional Speech X-Microsoft-OutputFormat value, e.g. riff-24khz-16bit-mono-pcm.",
    )
    parser.add_argument("--output", default="output.wav", help="Local file path to save the audio response.")
    parser.add_argument("--timeout", type=float, default=30.0, help="Request timeout in seconds.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not args.gateway_url:
        print("ERROR: --gateway-url (or APIM_GATEWAY_URL) is required.", file=sys.stderr)
        return 2
    if not args.subscription_key:
        print("ERROR: --subscription-key (or APIM_SUBSCRIPTION_KEY) is required.", file=sys.stderr)
        return 2

    url = f"{args.gateway_url.rstrip('/')}/speech/synthesize"
    payload = {"text": args.text}
    if args.voice:
        payload["voice"] = args.voice
    if args.language:
        payload["language"] = args.language
    if args.output_format:
        payload["outputFormat"] = args.output_format

    headers = {
        "Content-Type": "application/json",
        "Ocp-Apim-Subscription-Key": args.subscription_key,
    }

    print(f"POST {url}")
    try:
        response = requests.post(url, json=payload, headers=headers, timeout=args.timeout)
    except requests.RequestException as exc:
        print(f"ERROR: request failed: {exc}", file=sys.stderr)
        return 1

    content_type = response.headers.get("Content-Type", "<none>")
    print(f"HTTP status code: {response.status_code}")
    print(f"Response Content-Type: {content_type}")

    if response.status_code != 200:
        print("ERROR: request did not succeed. Response body:", file=sys.stderr)
        print(response.text, file=sys.stderr)
        return 1

    if not content_type.startswith("audio/"):
        print(
            f"WARNING: expected an audio/* content type but got '{content_type}'. "
            "Saving the response body anyway for inspection.",
            file=sys.stderr,
        )

    try:
        with open(args.output, "wb") as audio_file:
            audio_file.write(response.content)
    except OSError as exc:
        print(f"ERROR: could not write output file '{args.output}': {exc}", file=sys.stderr)
        return 1

    print(f"Saved {len(response.content)} bytes of audio to: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
