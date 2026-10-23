"""Portable data boundary. Models are bounded data, never generated executable code."""
import hashlib
import json
import math
import re
from dataclasses import dataclass
from typing import Protocol


class Problem(Exception):
    def __init__(self, code, message, status=409):
        super().__init__(message)
        self.code, self.status = code, status


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', value):
        raise Problem('invalid_id', 'Expected a bounded opaque identifier.', 400)
    return value


def validate_document(doc):
    if not isinstance(doc, dict) or set(doc) != {'format', 'label', 'objects'} or doc['format'] != 'editable-room/1':
        raise Problem('invalid_model', 'Unsupported room document.', 400)
    if not isinstance(doc['label'], str) or not 1 <= len(doc['label']) <= 120:
        raise Problem('invalid_model', 'Room label must have 1–120 characters.', 400)
    if not isinstance(doc['objects'], list) or not 1 <= len(doc['objects']) <= 500:
        raise Problem('invalid_model', 'Room must contain 1–500 objects.', 400)
    ids = set()
    for obj in doc['objects']:
        if not isinstance(obj, dict) or set(obj) != {'id', 'label', 'kind', 'position', 'size', 'color'}:
            raise Problem('invalid_model', 'Unsupported object fields.', 400)
        identifier(obj['id'])
        if obj['id'] in ids or obj['kind'] != 'box':
            raise Problem('invalid_model', 'Objects require unique IDs and supported geometry.', 400)
        ids.add(obj['id'])
        if not isinstance(obj['label'], str) or not 1 <= len(obj['label']) <= 120:
            raise Problem('invalid_model', 'Invalid object label.', 400)
        if not isinstance(obj['color'], str) or not re.fullmatch(r'#[0-9a-fA-F]{6}', obj['color']):
            raise Problem('invalid_model', 'Expected an RGB color.', 400)
        for key in ('position', 'size'):
            v = obj[key]
            if not isinstance(v, list) or len(v) != 3 or any(type(n) not in (int, float) or not math.isfinite(n) or abs(n) > 100 for n in v):
                raise Problem('invalid_model', 'Geometry must be finite meters within 100 m.', 400)
            if key == 'size' and any(n <= 0 for n in v):
                raise Problem('invalid_model', 'Object dimensions must be positive.', 400)
    return doc


@dataclass(frozen=True)
class Principal:
    subject: str
    can_model: bool = False  # App authorization to spend usage, never inferred from Site login.
    can_publish: bool = False


@dataclass(frozen=True)
class TaskProgress:
    state: str  # running | complete | failed | unknown


class CloudRunner(Protocol):
    def submit(self, job_id: str, scan: dict) -> str: ...
    def status(self, task_id: str) -> TaskProgress: ...
    def result(self, task_id: str, scan: dict) -> dict: ...


class PrivateTransfer(Protocol):
    """Deployment-owned gateway: short-lived scoped input and output grants; no Git payloads."""
    def prompt(self, job_id: str, scan: dict) -> str: ...
    def read_result(self, task_id: str, scan: dict) -> dict: ...


class SitePublisher(Protocol):
    """Publish idempotently to ONE pre-created private viewer; verify before acknowledging.

    Each request ID must always resolve to the same immutable revision. The adapter must
    use a conditional pointer update and authorize every model/texture/geometry endpoint.
    """
    def publish(self, request_id: str, room_id: str, revision: dict, expected: str | None) -> str: ...


def synthetic_document():
    return {'format': 'editable-room/1', 'label': 'Synthetic studio', 'objects': [
        {'id': 'floor', 'label': 'Floor', 'kind': 'box', 'position': [0, -.05, 0], 'size': [5, .1, 4], 'color': '#cbbda6'},
        {'id': 'back', 'label': 'Back wall', 'kind': 'box', 'position': [0, 1.4, -2], 'size': [5, 2.8, .1], 'color': '#eee4d4'},
        {'id': 'side', 'label': 'Side wall', 'kind': 'box', 'position': [-2.5, 1.4, 0], 'size': [.1, 2.8, 4], 'color': '#d8cdbb'},
        {'id': 'table', 'label': 'Table', 'kind': 'box', 'position': [.5, .45, 0], 'size': [1.8, .9, .85], 'color': '#c66635'},
    ]}
