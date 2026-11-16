"""Dispose of the test's own Qt window without prompting about its temporary edits."""
from unittest.mock import patch


def close_regression_window(window):
    with patch.object(window, "can_leave_project", return_value=True):
        window.close()
