"""Volcengine RTC signing and voice-agent calls adapted from SayPal's rtc_gateway.py."""

import base64
import hashlib
import hmac
import json
import logging
import os
import secrets
import struct
import time
from datetime import datetime, timezone

import httpx

HOST = 'rtc.volcengineapi.com'
VERSION = '2024-12-01'
VOICE_PRESETS = {
    'vivi': 'zh_female_vv_uranus_bigtts',
    'xiaohe': 'zh_female_xiaohe_uranus_bigtts',
    'yunzhou': 'zh_male_m191_uranus_bigtts',
    'xiaotian': 'zh_male_taocheng_uranus_bigtts',
}
REQUIRED = (
    'VOLC_RTC_APP_ID', 'VOLC_RTC_APP_KEY', 'VOLC_ACCESS_KEY', 'VOLC_SECRET_KEY',
    'OPENSPEECH_APP_ID', 'OPENSPEECH_VOICE_TYPE', 'ARK_MODEL_ID',
)
log = logging.getLogger(__name__)


def configured():
    return all(os.getenv(key, '').strip() for key in REQUIRED) and bool(
        os.getenv('OPENSPEECH_API_KEY', '').strip()
        or os.getenv('OPENSPEECH_ACCESS_TOKEN', '').strip()
    )


def _sized(value: bytes) -> bytes:
    return struct.pack('<H', len(value)) + value


def issue_token(room_id: str, user_id: str, expires_at: int) -> str:
    message = (
        struct.pack('<III', secrets.randbelow(99_999_999) + 1, int(time.time()), expires_at)
        + _sized(room_id.encode()) + _sized(user_id.encode())
        + struct.pack('<HHI', 1, 4, expires_at)  # SubscribeStream
    )
    signature = hmac.digest(os.environ['VOLC_RTC_APP_KEY'].strip().encode(), message, 'sha256')
    return '001' + os.environ['VOLC_RTC_APP_ID'].strip() + base64.b64encode(
        _sized(message) + _sized(signature)
    ).decode('ascii')


def _signed_headers(action: str, payload: bytes) -> dict[str, str]:
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    day = stamp[:8]
    region = os.getenv('VOLC_RTC_REGION', 'cn-north-1').strip()
    service = 'rtc'
    digest = hashlib.sha256(payload).hexdigest()
    content_type = 'application/json; charset=utf-8'
    signed = 'host;x-date;x-content-sha256;content-type'
    canonical = (
        f'POST\n/\nAction={action}&Version={VERSION}\n'
        f'host:{HOST}\nx-date:{stamp}\nx-content-sha256:{digest}\n'
        f'content-type:{content_type}\n\n{signed}\n{digest}'
    )
    scope = f'{day}/{region}/{service}/request'
    target = f'HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
    key = os.environ['VOLC_SECRET_KEY'].strip().encode()
    for part in (day, region, service, 'request'):
        key = hmac.digest(key, part.encode(), 'sha256')
    signature = hmac.digest(key, target.encode(), 'sha256').hex()
    access_key = os.environ['VOLC_ACCESS_KEY'].strip()
    return {
        'Host': HOST, 'X-Date': stamp, 'X-Content-Sha256': digest, 'Content-Type': content_type,
        'Authorization': (
            f'HMAC-SHA256 Credential={access_key}/{scope}, '
            f'SignedHeaders={signed}, Signature={signature}'
        ),
    }


class RtcError(Exception):
    pass


async def call(client: httpx.AsyncClient, action: str, body: dict):
    payload = json.dumps(
        {'AppId': os.environ['VOLC_RTC_APP_ID'].strip(), **body},
        ensure_ascii=False, separators=(',', ':'),
    ).encode()
    try:
        response = await client.post(
            f'https://{HOST}/?Action={action}&Version={VERSION}',
            headers=_signed_headers(action, payload), content=payload,
        )
        metadata = response.json()['ResponseMetadata']
        if not isinstance(metadata, dict):
            raise ValueError('Invalid response metadata')
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        log.warning('RTC %s returned no usable response (%s)', action, type(exc).__name__)
        raise RtcError(action) from None
    error = metadata.get('Error')
    if not response.is_success or error:
        code = error.get('CodeN') if isinstance(error, dict) else None
        log.warning('RTC %s rejected (HTTP %d, code %r)', action, response.status_code, code)
        raise RtcError(action)


def default_speaker() -> str:
    return os.environ['OPENSPEECH_VOICE_TYPE'].strip()


def agent_config(user_id: str, bot_id: str, speaker: str | None = None) -> dict:
    speech_app_id = os.environ['OPENSPEECH_APP_ID'].strip()
    speech_key = (os.getenv('OPENSPEECH_API_KEY') or os.environ['OPENSPEECH_ACCESS_TOKEN']).strip()
    return {
        'AgentConfig': {
            'UserId': bot_id,
            'TargetUserId': [user_id],
            'EnableConversationStateCallback': True,
        },
        'Config': {
            'ASRConfig': {
                'Provider': 'volcano',
                'TurnDetectionMode': 1,
                'ProviderParams': {
                    'Mode': 'bigmodel',
                    'AppId': os.getenv('RTC_ASR_APP_ID', speech_app_id).strip(),
                    'AccessToken': os.getenv('RTC_ASR_ACCESS_TOKEN', speech_key).strip(),
                    'ApiResourceId': os.getenv('RTC_ASR_RESOURCE_ID', 'volc.bigasr.sauc.duration').strip(),
                },
            },
            'LLMConfig': {
                'Mode': 'ArkV3',
                'EndPointId': os.environ['ARK_MODEL_ID'].strip(),
                'SystemMessages': ['你是 LifePages 的语音播报助手。'],
                'ThinkingType': 'disabled',
            },
            'TTSConfig': {
                'Provider': 'volcano_bidirection',
                'ProviderParams': {
                    'Credential': {
                        'AppId': os.getenv('RTC_TTS_APP_ID', speech_app_id).strip(),
                        'Token': os.getenv('RTC_TTS_ACCESS_TOKEN', speech_key).strip(),
                        'ResourceId': os.getenv('RTC_TTS_RESOURCE_ID', 'seed-tts-2.0').strip(),
                    },
                    'VolcanoTTSParameters': json.dumps({'req_params': {
                        'speaker': speaker if speaker is not None else default_speaker(),
                        'audio_params': {'speech_rate': 0, 'loudness_rate': 0},
                        'additions': {'context_texts': [
                            '用同一个声音，平稳、轻柔地朗读，保持自然一致的语速和音高，不模仿文中的人物。',
                        ]},
                    }}, ensure_ascii=False, separators=(',', ':')),
                },
            },
        },
    }
