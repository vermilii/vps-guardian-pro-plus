import subprocess
def _run(cmd):
    try: subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True); return True
    except Exception: return False
def block_ip(ip: str) -> bool:
    if _run(["nft","add","rule","inet","filter","input","ip","saddr",ip,"drop"]): return True
    return _run(["iptables","-I","INPUT","-s",ip,"-j","DROP"])
def unblock_ip(ip: str) -> bool:
    if _run(["nft","delete","rule","inet","filter","input","ip","saddr",ip,"drop"]): return True
    return _run(["iptables","-D","INPUT","-s",ip,"-j","DROP"])
