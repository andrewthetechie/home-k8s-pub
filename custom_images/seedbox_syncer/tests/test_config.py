import os
from unittest.mock import patch
import pytest
import sync_media

def test_get_config_raises_when_required_missing():
    with pytest.raises(ValueError, match="Missing required env"):
        with patch.dict(os.environ, {k: "" for k in sync_media.REQUIRED_ENV}, clear=False):
            sync_media.get_config()
