import json
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional, Dict, List

REGIONS = {
    "Australia": "https://app.au.action1.com/api/3.0",
    "Europe": "https://app.eu.action1.com/api/3.0",
    "NorthAmerica": "https://app.action1.com/api/3.0",
    "NorthAmerica-2": "https://app.na-2.action1.com/api/3.0",
}

class Action1Error(RuntimeError):
    pass

class Action1Client:
    def __init__(self, region: str, client_id: str, client_secret: str):
        if region not in REGIONS:
            raise Action1Error(f"Unsupported region: {region}")
        self.region = region
        self.base_url = REGIONS[region]
        self.client_id = client_id
        self._client_secret = client_secret
        self._access_token: Optional[str] = None
        self._token_expiry = 0.0

    def authenticate(self) -> None:
        payload = urllib.parse.urlencode({"client_id": self.client_id, "client_secret": self._client_secret}).encode("utf-8")
        req = urllib.request.Request(
            f"{self.base_url}/oauth2/token",
            data=payload,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        data = self._request_with_retry(req)
        token = data.get("access_token")
        if not token:
            raise Action1Error("Action1 authentication response did not include an access_token.")
        self._access_token = token
        self._token_expiry = time.time() + max(60, int(data.get("expires_in", 3600)) - 60)
        self._client_secret = ""

    def _ensure_token(self) -> None:
        if not self._access_token or time.time() >= self._token_expiry:
            raise Action1Error("The Action1 token has expired. Reconnect; DadLAN does not persist the Client Secret.")

    @staticmethod
    def _request_with_retry(req: urllib.request.Request, max_retries=3) -> dict:
        for attempt in range(max_retries):
            try:
                with urllib.request.urlopen(req, timeout=30) as response:
                    raw = response.read().decode("utf-8")
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as exc:
                if exc.code == 429:
                    retry_after = exc.headers.get("Retry-After")
                    sleep_time = int(retry_after) if retry_after and retry_after.isdigit() else (attempt + 1) * 2
                    time.sleep(sleep_time)
                    continue
                body = exc.read().decode("utf-8", errors="replace")
                try:
                    detail = json.loads(body)
                    detail_text = detail.get("message") or detail.get("error_description") or body
                except Exception:
                    detail_text = body
                raise Action1Error(f"Action1 HTTP {exc.code}: {detail_text}") from exc
            except urllib.error.URLError as exc:
                if attempt == max_retries - 1:
                    raise Action1Error(f"Could not reach Action1: {exc.reason}") from exc
                time.sleep((attempt + 1) * 2)
        raise Action1Error("Max retries exceeded for Action1 request.")

    def get(self, path_or_url: str, params: Optional[Dict[str, str]] = None) -> dict:
        self._ensure_token()
        url = path_or_url if path_or_url.startswith(("http://", "https://")) else f"{self.base_url}/{path_or_url.lstrip('/')}"
        if params:
            query = urllib.parse.urlencode(params)
            url += ("&" if "?" in url else "?") + query
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self._access_token}", "Accept": "application/json"}, method="GET")
        return self._request_with_retry(req)

    def post(self, path_or_url: str, payload: dict) -> dict:
        self._ensure_token()
        url = path_or_url if path_or_url.startswith(("http://", "https://")) else f"{self.base_url}/{path_or_url.lstrip('/')}"
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={"Authorization": f"Bearer {self._access_token}", "Accept": "application/json", "Content-Type": "application/json"}, method="POST")
        return self._request_with_retry(req)

    def _paged_items(self, path: str, params: Optional[Dict[str, str]] = None) -> List[dict]:
        items: List[dict] = []
        url: Optional[str] = path
        first = True
        while url:
            page = self.get(url, params if first else None)
            first = False
            items.extend(page.get("items", []))
            url = page.get("next_page") or None
        return items

    def organizations(self) -> List[dict]:
        return self._paged_items("organizations", {"limit": "50"})

    def endpoints(self, org_id: str) -> List[dict]:
        return self._paged_items(f"endpoints/managed/{urllib.parse.quote(org_id, safe='')}", {"fields": "*", "limit": "50"})

    def endpoint(self, org_id: str, endpoint_id: str) -> dict:
        return self.get(f"endpoints/managed/{urllib.parse.quote(org_id, safe='')}/{urllib.parse.quote(endpoint_id, safe='')}", {"fields": "*"})

    def run_script(self, org_id: str, endpoint_id: str, script_content: str, name: str = "DadLAN Automation",
                    retry_minutes: str = "1440", display_summary: str = "DadLAN Automation") -> dict:
        # Endpoint and payload shape verified 2026-09-09 against the live Action1 API by
        # inspecting a real UI-created run_script instance (GET /policies/instances/{org}/{id})
        # and reproducing it programmatically end-to-end (POST -> poll -> matching output).
        # Creation goes to /policies/instances/{org_id} (matches Action1's own PSAction1
        # client's New-Action1 Remediation/DeploySoftware mapping); the created instance is
        # then readable under /automations/instances/{org_id}/{instance_id} either way.
        return self.post(f"policies/instances/{urllib.parse.quote(org_id, safe='')}", {
            "name": name,
            "retry_minutes": retry_minutes,
            "endpoints": [
                {
                    "id": endpoint_id,
                    "type": "Endpoint"
                }
            ],
            "actions": [
                {
                    "name": "Run Script",
                    "template_id": "run_script",
                    "params": {
                        "display_summary": display_summary,
                        "condition_script_text": "",
                        "condition_script_file_name": "",
                        "condition_script_language": "PowerShell",
                        "run_script_params": [],
                        "run_script_text": script_content,
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
        })

    def get_instance(self, org_id: str, instance_id: str) -> dict:
        return self.get(f"automations/instances/{urllib.parse.quote(org_id, safe='')}/{urllib.parse.quote(instance_id, safe='')}")

    def wait_for_completion(self, org_id: str, instance_id: str, timeout_seconds: int = 120, poll_seconds: int = 4) -> dict:
        """Poll an instance until it leaves the Running state. Returns the final
        instance object. Raises Action1Error on timeout rather than looping forever."""
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            instance = self.get_instance(org_id, instance_id)
            status = instance.get("status")
            if status and status != "Running":
                return instance
            time.sleep(poll_seconds)
        raise Action1Error(f"Action1 instance {instance_id} did not complete within {timeout_seconds}s.")

    def stop_automation(self, org_id: str, instance_id: str) -> dict:
        return self.post(f"automations/instances/{urllib.parse.quote(org_id, safe='')}/{urllib.parse.quote(instance_id, safe='')}/stop", {})

    def automation_endpoint_results(self, org_id: str, instance_id: str) -> List[dict]:
        return self._paged_items(f"automations/instances/{urllib.parse.quote(org_id, safe='')}/{urllib.parse.quote(instance_id, safe='')}/endpoint-results")

    def automation_endpoint_details(self, org_id: str, instance_id: str, endpoint_id: str) -> dict:
        return self.get(f"automations/instances/{urllib.parse.quote(org_id, safe='')}/{urllib.parse.quote(instance_id, safe='')}/endpoint-results/{urllib.parse.quote(endpoint_id, safe='')}/details")
