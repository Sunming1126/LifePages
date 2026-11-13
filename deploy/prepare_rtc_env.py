"""Copy SayPal's allowlisted RTC settings into a private systemd EnvironmentFile."""

import argparse
import os
import re
import shlex
from pathlib import Path

ALLOWED = {
    'VOLC_RTC_APP_ID', 'VOLC_RTC_APP_KEY', 'VOLC_RTC_REGION', 'VOLC_ACCESS_KEY', 'VOLC_SECRET_KEY',
    'OPENSPEECH_APP_ID', 'OPENSPEECH_API_KEY', 'OPENSPEECH_ACCESS_TOKEN', 'OPENSPEECH_VOICE_TYPE',
    'ARK_MODEL_ID', 'RTC_ASR_APP_ID', 'RTC_ASR_ACCESS_TOKEN', 'RTC_ASR_RESOURCE_ID',
    'RTC_TTS_APP_ID', 'RTC_TTS_ACCESS_TOKEN', 'RTC_TTS_RESOURCE_ID',
}


def prepare(source: Path, destination: Path, *, voice: str, resource: str):
    values = {}
    for line in source.read_text().splitlines():
        match = re.fullmatch(r'\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*)', line)
        if not match or match[1] not in ALLOWED:
            continue
        name, raw = match.groups()
        try:
            parts = shlex.split(raw, comments=True)
        except ValueError:
            raise ValueError(f'Invalid RTC setting {name}') from None
        if not parts or parts == ['']:
            continue
        if len(parts) != 1 or not re.fullmatch(r'[A-Za-z0-9_.:/+=@-]+', parts[0]):
            raise ValueError(f'Invalid RTC setting {name}')
        values[name] = parts[0]
    if not re.fullmatch(r'[A-Za-z0-9]{24}', values.get('VOLC_RTC_APP_ID', '')):
        raise ValueError('Invalid RTC app ID')
    for name, value in (('OPENSPEECH_VOICE_TYPE', voice), ('RTC_TTS_RESOURCE_ID', resource)):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', value):
            raise ValueError(f'Invalid RTC setting {name}')
        values[name] = value
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as file:
        for name, value in values.items():
            file.write(f'{name}={value}\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--voice', required=True)
    parser.add_argument('--resource', required=True)
    args = parser.parse_args()
    prepare(args.source, args.destination, voice=args.voice, resource=args.resource)
