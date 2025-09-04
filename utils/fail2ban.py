import subprocess
def available() -> bool:
    return subprocess.call(["which","fail2ban-client"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
def _f2b(*args) -> bool:
    try: subprocess.run(["fail2ban-client", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True); return True
    except Exception: return False
def status() -> str:
    try: return subprocess.check_output(["fail2ban-client","status"], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception: return "Fail2ban not available."
def status_jail(jail: str) -> str:
    try: return subprocess.check_output(["fail2ban-client","status",jail], text=True, stderr=subprocess.DEVNULL).strip()
    except Exception: return f"Fail2ban jail {jail} not available."
def banip(jail: str, ip: str) -> bool: return _f2b("set", jail, "banip", ip)
def unbanip(jail: str, ip: str) -> bool: return _f2b("set", jail, "unbanip", ip)
