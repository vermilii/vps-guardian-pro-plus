import requests
class CF:
    def __init__(self, api_token: str, zone_id: str):
        self.api_token=api_token; self.zone_id=zone_id; self.base=f"https://api.cloudflare.com/client/v4/zones/{zone_id}"
    def _headers(self): return {"Authorization": f"Bearer {self.api_token}", "Content-Type":"application/json"}
    def status(self):
        try:
            r=requests.get(f"{self.base}", headers=self._headers(), timeout=10); return f"Cloudflare zone status: HTTP {r.status_code}"
        except Exception as e: return f"Cloudflare status error: {e}"
    def block_ip(self, ip: str) -> bool:
        try:
            data={"mode":"block","configuration":{"target":"ip","value":ip},"notes":"VPS Guardian block"}
            r=requests.post(f"{self.base}/firewall/access_rules/rules", headers=self._headers(), json=data, timeout=10); return r.ok
        except Exception: return False
    def unblock_ip(self, ip: str) -> bool:
        try:
            r=requests.get(f"{self.base}/firewall/access_rules/rules?per_page=50", headers=self._headers(), timeout=10)
            if not r.ok: return False
            for item in r.json().get("result", []):
                if item.get("configuration",{}).get("value")==ip:
                    did=item.get("id"); d=requests.delete(f"{self.base}/firewall/access_rules/rules/{did}", headers=self._headers(), timeout=10); return d.ok
            return False
        except Exception: return False
    def under_attack(self, on: bool) -> bool:
        try:
            data={"value":"under_attack" if on else "high"}
            r=requests.patch(f"{self.base}/settings/security_level", headers=self._headers(), json=data, timeout=10); return r.ok
        except Exception: return False
