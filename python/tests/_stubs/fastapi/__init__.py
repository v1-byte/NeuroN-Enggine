# STUB untuk smoke test tanpa jaringan. Hanya meniru bentuk API yang dipakai server.py, bukan perilaku FastAPI sungguhan.
class FastAPI:
    def __init__(self, title="", dependencies=None, **kw):
        self.title, self.dependencies, self.routes = title, dependencies or [], []
    def _route(self, method, path):
        def deco(fn):
            self.routes.append((method, path, fn))
            return fn
        return deco
    def get(self, path, **kw): return self._route("GET", path)
    def post(self, path, **kw): return self._route("POST", path)
    def delete(self, path, **kw): return self._route("DELETE", path)

class HTTPException(Exception):
    def __init__(self, status_code, detail=""):
        super().__init__(detail)
        self.status_code, self.detail = status_code, detail

def Depends(fn): return fn
def Header(default=None, **kw): return default
def File(default=None, **kw): return default

class UploadFile:
    def __init__(self, filename=""): self.filename = filename
