import unittest
import json
from unittest.mock import MagicMock, patch
from diagnostics import get_diagnostic
from database import init_db, log_action, get_history
import os
import time

class TestDadLAN(unittest.TestCase):
    def test_diagnostic_registry(self):
        diag = get_diagnostic("system_snapshot")
        self.assertEqual(diag["id"], "system_snapshot")
        self.assertIn("Get-CimInstance", diag["script"])
        
        with self.assertRaises(ValueError):
            get_diagnostic("unknown")

    def test_database_history(self):
        os.environ["XDG_DATA_HOME"] = "/tmp/dadlan_test_data"
        init_db()
        log_action("Laptop 02", "System Snapshot", "inst_123", "Success", "1000 ms", '{"test": "data"}')
        history = get_history(1)
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["target"], "Laptop 02")
        self.assertEqual(history[0]["status"], "Success")

    @patch('action1_client.urllib.request.urlopen')
    def test_action1_client(self, mock_urlopen):
        from action1_client import Action1Client
        
        client = Action1Client("Australia", "cid", "sec")
        mock_response = MagicMock()
        mock_response.read.return_value = b'{"access_token": "token123", "expires_in": 3600}'
        mock_urlopen.return_value.__enter__.return_value = mock_response
        
        client.authenticate()
        self.assertEqual(client._access_token, "token123")
        
        mock_response.read.return_value = b'{"id": "inst_123"}'
        res = client.run_script("org1", "ep1", "echo 1")
        self.assertEqual(res.get("id"), "inst_123")

        # Verify the payload structure. This shape (and the policies/instances path)
        # was confirmed 2026-09-09 against the real Action1 API: a run_script instance
        # created through the Action1 web UI was fetched via
        # GET /policies/instances/{org}/{id} and used as ground truth, then this exact
        # request shape was POSTed for real, polled to completion, and its output
        # matched the target machine's real hostname end to end.
        call_args = mock_urlopen.call_args[0][0]
        self.assertTrue(call_args.full_url.endswith("policies/instances/org1"))
        payload = json.loads(call_args.data.decode('utf-8'))

        expected_payload = {
            "name": "DadLAN Automation",
            "retry_minutes": "1440",
            "endpoints": [
                {
                    "id": "ep1",
                    "type": "Endpoint"
                }
            ],
            "actions": [
                {
                    "name": "Run Script",
                    "template_id": "run_script",
                    "params": {
                        "display_summary": "DadLAN Automation",
                        "condition_script_text": "",
                        "condition_script_file_name": "",
                        "condition_script_language": "PowerShell",
                        "run_script_params": [],
                        "run_script_text": "echo 1",
                        "run_script_file_name": "",
                        "run_script_language": "PowerShell",
                        "platform": "Windows",
                        "reboot_exit_codes": "",
                        "reboot_options": {
                            "auto_reboot": "no",
                            "show_message": "no",
                            "message_text": "",
                            "timeout": 240
                        }
                    }
                }
            ]
        }
        self.assertEqual(payload, expected_payload)

    @patch('action1_client.urllib.request.urlopen')
    def test_wait_for_completion_returns_on_terminal_status(self, mock_urlopen):
        from action1_client import Action1Client
        client = Action1Client("Australia", "cid", "sec")
        mock_response = MagicMock()
        mock_response.read.return_value = b'{"access_token": "token123", "expires_in": 3600}'
        mock_urlopen.return_value.__enter__.return_value = mock_response
        client.authenticate()

        mock_response.read.return_value = b'{"status": "Success", "id": "inst_1"}'
        result = client.wait_for_completion("org1", "inst_1", timeout_seconds=5, poll_seconds=0)
        self.assertEqual(result["status"], "Success")

    @patch('action1_client.time.sleep', return_value=None)
    @patch('action1_client.urllib.request.urlopen')
    def test_wait_for_completion_times_out_instead_of_looping_forever(self, mock_urlopen, mock_sleep):
        from action1_client import Action1Client, Action1Error
        client = Action1Client("Australia", "cid", "sec")
        mock_response = MagicMock()
        mock_response.read.return_value = b'{"access_token": "token123", "expires_in": 3600}'
        mock_urlopen.return_value.__enter__.return_value = mock_response
        client.authenticate()

        mock_response.read.return_value = b'{"status": "Running", "id": "inst_1"}'
        with self.assertRaises(Action1Error):
            client.wait_for_completion("org1", "inst_1", timeout_seconds=0.01, poll_seconds=0.01)

    def test_safety_controller_protection(self):
        from dadlan import MachineMeta, DadLANApp
        import tkinter as tk
        app = DadLANApp()
        
        # Laptop 01 (Controller) should always be disabled, even if protected=False
        meta_controller = MachineMeta("ep1", "01", "Laptop 01", "Controller", "", False)
        app.metadata["ep1"] = meta_controller
        app.endpoints = [{"id": "ep1", "name": "Laptop 01"}]
        app.tree.insert("", "end", iid="ep1")
        app.tree.selection_set("ep1")
        app._show_selected_details()
        self.assertEqual(str(app.snapshot_button.cget("state")), "disabled")

        # Laptop 02 (Worker) but protected=True should be disabled
        meta_protected_worker = MachineMeta("ep2", "02", "Laptop 02", "Worker", "", True)
        app.metadata["ep2"] = meta_protected_worker
        app.endpoints.append({"id": "ep2", "name": "Laptop 02"})
        app.tree.insert("", "end", iid="ep2")
        app.tree.selection_set("ep2")
        app._show_selected_details()
        self.assertEqual(str(app.snapshot_button.cget("state")), "disabled")

        # Laptop 02 (Worker) unprotected should be enabled
        meta_unprotected_worker = MachineMeta("ep3", "02", "Laptop 02", "Worker", "", False)
        app.metadata["ep3"] = meta_unprotected_worker
        app.endpoints.append({"id": "ep3", "name": "Laptop 02"})
        app.tree.insert("", "end", iid="ep3")
        app.tree.selection_set("ep3")
        app._show_selected_details()
        self.assertEqual(str(app.snapshot_button.cget("state")), "normal")

        # Multiple endpoints selected should be disabled
        app.tree.selection_set("ep2", "ep3")
        app._show_selected_details()
        self.assertEqual(str(app.snapshot_button.cget("state")), "disabled")

        app.destroy()

if __name__ == '__main__':
    unittest.main()
