from unittest.mock import patch, MagicMock

import sync_media

def test_parse_wan_status_wan1():
    data = [{"subsystem": "wan", "uptime_stats": {"WAN": {"availability": 99}, "WAN2": {"availability": 0}}}]
    assert sync_media.parse_wan_status(data, 1.0) == "WAN1"

def test_parse_wan_status_wan2():
    data = [{"subsystem": "wan", "uptime_stats": {"WAN": {"availability": 0}, "WAN2": {"availability": 99}}}]
    assert sync_media.parse_wan_status(data, 1.0) == "WAN2"

def test_parse_wan_status_offline():
    data = [{"subsystem": "wan", "uptime_stats": {"WAN": {"availability": 0}, "WAN2": {"availability": 0}}}]
    assert sync_media.parse_wan_status(data, 1.0) == "Offline"

def test_parse_wan_status_empty_data_offline():
    assert sync_media.parse_wan_status([], 1.0) == "Offline"

def test_get_isp_status_returns_wan1_on_success():
    config = {"udm_ip": "192.168.1.1", "udm_username": "u", "udm_password": "p", "avail_threshold": 1.0}
    with patch("sync_media.requests") as req:
        session = MagicMock()
        session.post.return_value = MagicMock(status_code=200, cookies=MagicMock(get_dict=lambda: {}))
        session.get.return_value = MagicMock(
            status_code=200,
            json=lambda: {"data": [{"subsystem": "wan", "uptime_stats": {"WAN": {"availability": 99}, "WAN2": {}}}]}
        )
        req.Session.return_value = session
        assert sync_media.get_isp_status(config) == "WAN1"
