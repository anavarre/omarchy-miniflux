#!/usr/bin/env python3
"""Runs the QtTest cases in this directory against Service.qml.

PySide6 ships no qmltestrunner binary, but it does ship QUICK_TEST_MAIN,
which is the same runner. Quickshell.Io resolves to tests/qml/fakes, whose
Process never runs anything and is finished by the test. Extra arguments
are passed to the runner (e.g. -functions, -v2).
"""
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtQuickTest import QUICK_TEST_MAIN  # noqa: E402

here = os.path.dirname(os.path.abspath(__file__))
fakes = os.path.join(here, "..", "fakes")
argv = [sys.argv[0], "-import", fakes, "-input", here] + sys.argv[1:]
sys.exit(QUICK_TEST_MAIN("service", argv))
