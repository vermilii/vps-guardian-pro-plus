import threading, http.server, socketserver, psutil
_metrics={"cpu":0.0,"mem":0.0,"disk":0.0,"load_per_core":0.0,"processes":0,"blocked_ips":0}
def set_metric(name, value): _metrics[name]=value
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path!="/metrics": self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type","text/plain; version=0.0.4"); self.end_headers()
        lines=[f"guardian_cpu_percent {_metrics['cpu']}", f"guardian_mem_percent {_metrics['mem']}", f"guardian_disk_percent {_metrics['disk']}", f"guardian_load_per_core {_metrics['load_per_core']}", f"guardian_processes {_metrics['processes']}", f"guardian_blocked_ips {_metrics['blocked_ips']}"]
        self.wfile.write(("\n".join(lines)+"\n").encode())
    def log_message(self, *a, **k): return
class Exporter(threading.Thread):
    def __init__(self, bind: str, port: int): super().__init__(daemon=True); self.bind=bind; self.port=port
    def run(self):
        with socketserver.TCPServer((self.bind,self.port), Handler) as httpd: httpd.serve_forever()
