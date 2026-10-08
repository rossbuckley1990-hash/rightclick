"""Reuse the frozen independent contract encoder without duplicating it."""
import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location("frozen_contract_pin", Path(__file__).with_name("acceptance-contract-pin.py"))
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
fingerprint = _module.fingerprint
