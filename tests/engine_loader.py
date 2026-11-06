"""Load bin/session-search.py as a module; its hyphen rules out a plain import."""

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

ENGINE_PATH = Path(__file__).resolve().parent.parent / "bin" / "session-search.py"
MODULE_NAME = "session_search_engine"


def load_engine() -> ModuleType:
    if MODULE_NAME in sys.modules:
        return sys.modules[MODULE_NAME]
    spec = importlib.util.spec_from_file_location(MODULE_NAME, ENGINE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module
